%%%-------------------------------------------------------------------
%%% @doc Request Queue with Rate Limiting & Pacing
%%% Guarantees requests are processed Line-by-Line (FIFO)
%%% at a controlled rate (e.g., 10 requests per minute = 1 req / 6s).
%%% @end
%%%-------------------------------------------------------------------
-module(request_queue).
-behaviour(gen_server).

%% API
-export([
    start_link/1,
    enqueue_sync/4,
    enqueue_sync/5,
    enqueue_async/4,
    get_stats/0,
    set_rate/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(queue_item, {
    id :: binary(),
    from :: {pid(), reference()} | async,
    method :: atom(),
    path :: string(),
    headers :: [{string(), string()}],
    body :: binary(),
    enqueued_at :: integer()
}).

-record(state, {
    queue = queue:new() :: queue:queue(),
    rate_per_min = 10 :: pos_integer(),
    interval_ms = 6000 :: pos_integer(),
    last_dispatch_time = 0 :: integer(),
    timer_ref = undefined :: reference() | undefined,
    total_enqueued = 0 :: non_neg_integer(),
    total_dispatched = 0 :: non_neg_integer()
}).

%%====================================================================
%% API Functions
%%====================================================================

start_link(RatePerMin) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, RatePerMin, []).

%% Synchronous: Client waits until request is paced, dispatched, and replied
enqueue_sync(Method, Path, Headers, Body) ->
    enqueue_sync(Method, Path, Headers, Body, 60000).

enqueue_sync(Method, Path, Headers, Body, Timeout) ->
    try gen_server:call(?MODULE, {enqueue_sync, Method, Path, Headers, Body}, Timeout)
    catch
        exit:{timeout, _Reason} ->
            {error, timeout}
    end.

%% Asynchronous: Client gets immediate ticket ID and queue position
enqueue_async(Method, Path, Headers, Body) ->
    gen_server:call(?MODULE, {enqueue_async, Method, Path, Headers, Body}).

get_stats() ->
    gen_server:call(?MODULE, get_stats).

set_rate(RatePerMin) when is_integer(RatePerMin) andalso RatePerMin > 0 ->
    gen_server:call(?MODULE, {set_rate, RatePerMin}).

%%====================================================================
%% gen_server Callbacks
%%====================================================================

init(RatePerMin) ->
    IntervalMs = max(100, (60 * 1000) div RatePerMin),
    {ok, #state{
        queue = queue:new(),
        rate_per_min = RatePerMin,
        interval_ms = IntervalMs,
        last_dispatch_time = 0,
        timer_ref = undefined,
        total_enqueued = 0,
        total_dispatched = 0
    }}.

handle_call({enqueue_sync, Method, Path, Headers, Body}, From, State) ->
    ReqId = generate_req_id(),
    Now = erlang:system_time(millisecond),
    Item = #queue_item{
        id = ReqId,
        from = From,
        method = Method,
        path = Path,
        headers = Headers,
        body = Body,
        enqueued_at = Now
    },
    NewState = handle_new_item(Item, State),
    %% Notice we do NOT reply to From immediately; the dispatcher will gen_server:reply
    {noreply, NewState};

handle_call({enqueue_async, Method, Path, Headers, Body}, _From, State) ->
    ReqId = generate_req_id(),
    Now = erlang:system_time(millisecond),
    Item = #queue_item{
        id = ReqId,
        from = async,
        method = Method,
        path = Path,
        headers = Headers,
        body = Body,
        enqueued_at = Now
    },
    NewState = handle_new_item(Item, State),
    QueueLength = queue:len(NewState#state.queue),
    EstimatedWaitSec = (QueueLength * NewState#state.interval_ms) div 1000,
    {reply, {ok, #{
        request_id => ReqId,
        queue_position => QueueLength,
        estimated_wait_seconds => EstimatedWaitSec,
        rate_per_min => NewState#state.rate_per_min
    }}, NewState};

handle_call(get_stats, _From, State) ->
    Len = queue:len(State#state.queue),
    Stats = #{
        queue_length => Len,
        rate_per_minute => State#state.rate_per_min,
        interval_ms => State#state.interval_ms,
        total_enqueued => State#state.total_enqueued,
        total_dispatched => State#state.total_dispatched,
        is_pacing_active => (State#state.timer_ref =/= undefined)
    },
    {reply, {ok, Stats}, State};

handle_call({set_rate, RatePerMin}, _From, State) ->
    IntervalMs = max(100, (60 * 1000) div RatePerMin),
    {reply, ok, State#state{rate_per_min = RatePerMin, interval_ms = IntervalMs}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(dispatch_tick, State) ->
    %% Timer fired: dispatch next item from the FIFO queue
    case queue:out(State#state.queue) of
        {{value, Item}, RemainingQueue} ->
            do_dispatch(Item),
            Now = erlang:system_time(millisecond),
            NewDispatched = State#state.total_dispatched + 1,
            
            %% If there are more items waiting, re-arm the timer
            NewTimerRef = case queue:is_empty(RemainingQueue) of
                false ->
                    erlang:send_after(State#state.interval_ms, self(), dispatch_tick);
                true ->
                    undefined
            end,
            {noreply, State#state{
                queue = RemainingQueue,
                last_dispatch_time = Now,
                timer_ref = NewTimerRef,
                total_dispatched = NewDispatched
            }};
        {empty, EmptyQueue} ->
            {noreply, State#state{queue = EmptyQueue, timer_ref = undefined}}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal Functions
%%====================================================================

handle_new_item(Item, State) ->
    Now = erlang:system_time(millisecond),
    Elapsed = Now - State#state.last_dispatch_time,
    QueueEmpty = queue:is_empty(State#state.queue),
    TimerActive = (State#state.timer_ref =/= undefined),

    NewTotalEnqueued = State#state.total_enqueued + 1,

    case QueueEmpty andalso (not TimerActive) andalso (Elapsed >= State#state.interval_ms) of
        true ->
            %% Can dispatch immediately because required interval has already passed!
            do_dispatch(Item),
            State#state{
                last_dispatch_time = Now,
                total_enqueued = NewTotalEnqueued,
                total_dispatched = State#state.total_dispatched + 1
            };
        false ->
            %% Must wait in line (FIFO queue)
            NewQueue = queue:in(Item, State#state.queue),
            NewTimerRef = case TimerActive of
                true ->
                    State#state.timer_ref;
                false ->
                    %% Schedule timer for remaining interval time
                    Delay = max(10, State#state.interval_ms - Elapsed),
                    erlang:send_after(Delay, self(), dispatch_tick)
            end,
            State#state{
                queue = NewQueue,
                timer_ref = NewTimerRef,
                total_enqueued = NewTotalEnqueued
            }
    end.

do_dispatch(#queue_item{method = Method, path = Path, headers = Headers, body = Body, from = From}) ->
    spawn(fun() ->
        dispatcher:dispatch(Method, Path, Headers, Body, From)
    end).

generate_req_id() ->
    Rand = integer_to_binary(rand:uniform(1000000)),
    Ts = integer_to_binary(erlang:system_time(microsecond)),
    <<"req_", Ts/binary, "_", Rand/binary>>.

