%% @copyright 2017 Takeru Ohta <phjgt308@gmail.com>
%%
%% @doc Thrift messages for jaeger
%%
%% IDL:
%% - https://github.com/jaegertracing/jaeger-idl/blob/84a83104/thrift/agent.thrift
%% - https://github.com/jaegertracing/jaeger-idl/blob/84a83104/thrift/jaeger.thrift
%%
%% @private
-module(jaeger_passage_thrift).

-include_lib("thrift_protocol/include/thrift_protocol.hrl").
-include("constants.hrl").

%%------------------------------------------------------------------------------
%% Application Internal API
%%------------------------------------------------------------------------------
-export([make_emit_batch_message/3]).

%%------------------------------------------------------------------------------
%% Macros
%%------------------------------------------------------------------------------
-define(TAG_TYPE_STRING, 0).
-define(TAG_TYPE_DOUBLE, 1).
-define(TAG_TYPE_BOOL, 2).
-define(TAG_TYPE_LONG, 3).
-define(TAG_TYPE_BINARY, 4).

-define(REF_TYPE_CHILD_OF, 0).
-define(REF_TYPE_FOLLOWS_FROM, 1).

-define(STRUCT(F1), #thrift_protocol_struct{fields = #{1 => F1}}).
-define(STRUCT(F1, F2), #thrift_protocol_struct{fields = #{1 => F1, 2 => F2}}).

-define(LIST(Es), #thrift_protocol_list{element_type = struct, elements = Es}).

%%------------------------------------------------------------------------------
%% Application Internal API
%%------------------------------------------------------------------------------
-spec make_emit_batch_message(atom(), passage:tags(), [passage_span:span()]) ->
                                     thrift_protocol:message().
make_emit_batch_message(ServiceName, ServiceTags, Spans) ->
    Process = make_process(ServiceName, ServiceTags),
    Batch = ?STRUCT(Process, make_spans(Spans)),
    #thrift_protocol_message{
       method_name  = <<"emitBatch">>,
       message_type = oneway,
       sequence_id  = 0,
       body         = ?STRUCT(Batch)
      }.

%%------------------------------------------------------------------------------
%% Internal Functions
%%------------------------------------------------------------------------------
-spec make_process(atom(), passage:tags()) -> thrift_protocol:struct().
make_process(ServiceName, ServiceTags) ->
    ?STRUCT(atom_to_binary(ServiceName, utf8), make_tags(ServiceTags)).

-spec make_tags(Tags) -> thrift_protocol:thrift_list() when
      Tags :: #{atom() => term()}.
make_tags(Tags) ->
    ?LIST(maps:fold(fun (K, V, Acc) -> [make_tag(K, V) | Acc] end, [], Tags)).

-spec make_tag(passage:tag_name(), passage:tag_value()) -> thrift_protocol:struct().
make_tag(Key, Value) ->
    {ValueType, FieldId, TagValue} = make_tag_value(Value),
    #thrift_protocol_struct{
       fields = #{
         1 => atom_to_binary(Key, utf8),
         2 => {i32, ValueType},
         FieldId => TagValue
        }
      }.

-spec make_tag_value(term()) -> {ValueType, FieldId, Value} when
      ValueType :: non_neg_integer(),
      FieldId   :: thrift_protocol:field_id(),
      Value     :: thrift_protocol:data().
make_tag_value(X) when is_boolean(X) -> {?TAG_TYPE_BOOL,   5, X};
make_tag_value(X) when is_atom(X)    -> {?TAG_TYPE_STRING, 3, atom_to_binary(X, utf8)};
make_tag_value(X) when is_binary(X)  -> {?TAG_TYPE_STRING, 3, X};
make_tag_value(X) when is_float(X)   -> {?TAG_TYPE_DOUBLE, 4, X};
make_tag_value(X) when is_integer(X) -> {?TAG_TYPE_LONG,   6, {i64, X}};
make_tag_value(X) ->
    Size = erlang:external_size(X),
    case Size > 1024 of
        true ->
            {?TAG_TYPE_STRING, 3,
             list_to_binary(io_lib:format("...~p bytes... (ommitted by ~p)",
                                          [Size, ?MODULE]))};
        false ->
            try list_to_binary(X) of
                Binary -> {?TAG_TYPE_STRING, 3, Binary}
            catch
                error:badarg ->
                    Binary = list_to_binary(io_lib:format("~1024p", [X])),
                    {?TAG_TYPE_STRING, 3, Binary}
            end
    end.

-spec make_spans([passage_span:span()]) -> thrift_protocol:thrift_list().
make_spans(Spans) ->
    ?LIST(lists:map(fun make_span/1, Spans)).

-spec make_span(passage_span:span()) -> thrift_protocol:struct().
make_span(Span) ->
    Context = passage_span:get_context(Span),
    TraceId = jaeger_passage_span_context:get_trace_id(Context),
    Refs =
        lists:filter(
          fun ({_, S}) ->
                  0 =/= jaeger_passage_span_context:get_span_id(passage_span:get_context(S))
          end,
          passage_span:get_refs(Span)),
    ParentSpanId =
        case Refs of
            [{_, Parent} | _] ->
                jaeger_passage_span_context:get_span_id(
                  passage_span:get_context(Parent));
            _ -> 0
        end,
    Tags0 = passage_span:get_tags(Span),
    Tags1 =
        case jaeger_passage_span_context:get_debug_id(Context) of
            error         -> Tags0;
            {ok, DebugId} -> maps:put(?JAEGER_DEBUG_HEADER, DebugId, Tags0)
        end,
    #thrift_protocol_struct{
       fields = #{
         1 => {i64, to_i64(TraceId)},
         2 => {i64, to_i64(TraceId bsr 64)},
         3 => {i64, to_i64(jaeger_passage_span_context:get_span_id(Context))},
         4 => {i64, to_i64(ParentSpanId)},
         5 => atom_to_binary(passage_span:get_operation_name(Span), utf8),
         6 => make_references(Refs),
         7 => {i32, jaeger_passage_span_context:get_flags(Context)},
         8 => {i64, timestamp_to_us(passage_span:get_start_time(Span))},
         9 => {i64, get_duration_us(Span)},
         10 => make_tags(Tags1),
         11 => make_logs(passage_span:get_logs(Span))
        }
      }.

-spec make_references(passage:refs()) -> thrift_protocol:thrift_list().
make_references(Refs) ->
    Elements =
        lists:filtermap(
          fun (Ref = {_, Span}) ->
                  Context = passage_span:get_context(Span),
                  case jaeger_passage_span_context:get_span_id(Context) of
                      0 -> false;
                      _ -> {true, make_reference(Ref)}
                  end
          end,
          Refs),
    ?LIST(Elements).

-spec make_reference(passage:ref()) -> thrift_protocol:struct().
make_reference(Ref) ->
    RefType =
        case Ref of
            {child_of, Span}     -> ?REF_TYPE_CHILD_OF;
            {follows_from, Span} -> ?REF_TYPE_FOLLOWS_FROM
        end,
    Context = passage_span:get_context(Span),
    TraceId = jaeger_passage_span_context:get_trace_id(Context),
    SpanId = jaeger_passage_span_context:get_span_id(Context),
    #thrift_protocol_struct{
       fields = #{
         1 => {i32, RefType},
         2 => {i64, to_i64(TraceId)},
         3 => {i64, to_i64(TraceId bsr 64)},
         4 => {i64, to_i64(SpanId)}
        }
      }.

-spec make_logs([passage_span:log()]) -> thrift_protocol:thrift_list().
make_logs(Logs) ->
    ?LIST(lists:map(fun make_log/1, Logs)).

-spec make_log(passage_span:log()) -> thrift_protocol:struct().
make_log({Fields, Time}) ->
    ?STRUCT({i64, timestamp_to_us(Time)}, make_tags(Fields)).

-spec timestamp_to_us(erlang:timestamp()) -> non_neg_integer().
timestamp_to_us(Timestamp) ->
    timer:now_diff(Timestamp, {0, 0, 0}).

-spec get_duration_us(passage_span:span()) -> non_neg_integer().
get_duration_us(Span) ->
    Start = passage_span:get_start_time(Span),
    {ok, Finish} = passage_span:get_finish_time(Span),
    timer:now_diff(Finish, Start).

-spec to_i64(non_neg_integer()) -> integer().
to_i64(N) ->
    <<S:64/signed>> = <<N:64>>,
    S.
