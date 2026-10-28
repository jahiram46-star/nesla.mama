%%%-------------------------------------------------------------------
%%% @doc Backend Manager
%%% Manages multi-backend endpoints (Xano and Cloud servers).
%%% Handles Round-Robin selection, health checks, and failovers.
%%% @end
%%%-------------------------------------------------------------------
-module(backend_manager).
-behaviour(gen_server).

%% API
-export([
    start_link/1,
    get_next_backend/0,
    report_status/2,
    list_backends/0,
    add_backend/3,
    remove_backend/1
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

-record(backend, {
    id :: atom() | binary() | string(),
    type :: xano | cloud | atom(),
    url :: string(),
    status = up :: up | down,
    fail_count = 0 :: non_neg_integer(),
    total_requests = 0 :: non_neg_integer(),
    successful_requests = 0 :: non_neg_integer()
}).

-record(state, {
    backends = [] :: [#backend{}],
    index = 1 :: pos_integer()
}).

%%====================================================================
%% API Functions
%%====================================================================

start_link(InitialBackends) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, InitialBackends, []).

-spec get_next_backend() -> {ok, {any(), atom(), string()}} | {error, term()}.
get_next_backend() ->
    gen_server:call(?MODULE, get_next).

-spec report_status(any(), success | failure) -> ok.
report_status(BackendId, Status) ->
    gen_server:cast(?MODULE, {report_status, BackendId, Status}).

-spec list_backends() -> {ok, [map()]}.
list_backends() ->
    gen_server:call(?MODULE, list_backends).

-spec add_backend(any(), atom(), string()) -> ok.
add_backend(Id, Type, Url) ->
    gen_server:call(?MODULE, {add_backend, Id, Type, Url}).

-spec remove_backend(any()) -> ok.
remove_backend(Id) ->
    gen_server:call(?MODULE, {remove_backend, Id}).

%%====================================================================
%% gen_server Callbacks
%%====================================================================

init(InitialBackends) ->
    Backends = [
        #backend{
            id = Id,
            type = Type,
            url = strip_trailing_slash(Url),
            status = up,
            fail_count = 0
        }
        || {Id, Type, Url} <- InitialBackends
    ],
    {ok, #state{backends = Backends, index = 1}}.

handle_call(get_next, _From, #state{backends = []} = State) ->
    {reply, {error, no_backends_available}, State};

handle_call(get_next, _From, #state{backends = Backends, index = Index} = State) ->
    %% Filter healthy backends
    UpBackends = [B || B <- Backends, B#backend.status =:= up],
    case UpBackends of
        [] ->
            %% If all are marked down, fallback to any available to prevent total stall
            [Fallback | _] = Backends,
            {reply, {ok, {Fallback#backend.id, Fallback#backend.type, Fallback#backend.url}}, State};
        _ ->
            Total = length(UpBackends),
            SafeIndex = ((Index - 1) rem Total) + 1,
            Chosen = lists:nth(SafeIndex, UpBackends),
            NextIndex = (Index rem Total) + 1,
            {reply, {ok, {Chosen#backend.id, Chosen#backend.type, Chosen#backend.url}}, State#state{index = NextIndex}}
    end;

handle_call(list_backends, _From, #state{backends = Backends} = State) ->
    Result = [
        #{
            id => B#backend.id,
            type => B#backend.type,
            url => list_to_binary(B#backend.url),
            status => B#backend.status,
            fail_count => B#backend.fail_count,
            total_requests => B#backend.total_requests,
            successful_requests => B#backend.successful_requests
        }
        || B <- Backends
    ],
    {reply, {ok, Result}, State};

handle_call({add_backend, Id, Type, Url}, _From, #state{backends = Backends} = State) ->
    CleanUrl = strip_trailing_slash(Url),
    NewBackend = #backend{id = Id, type = Type, url = CleanUrl, status = up},
    Filtered = [B || B <- Backends, B#backend.id =/= Id],
    {reply, ok, State#state{backends = Filtered ++ [NewBackend]}};

handle_call({remove_backend, Id}, _From, #state{backends = Backends} = State) ->
    Filtered = [B || B <- Backends, B#backend.id =/= Id],
    {reply, ok, State#state{backends = Filtered}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({report_status, BackendId, success}, #state{backends = Backends} = State) ->
    Updated = lists:map(fun(B) ->
        case B#backend.id =:= BackendId of
            true ->
                B#backend{
                    status = up,
                    fail_count = 0,
                    total_requests = B#backend.total_requests + 1,
                    successful_requests = B#backend.successful_requests + 1
                };
            false ->
                B
        end
    end, Backends),
    {noreply, State#state{backends = Updated}};

handle_cast({report_status, BackendId, failure}, #state{backends = Backends} = State) ->
    Updated = lists:map(fun(B) ->
        case B#backend.id =:= BackendId of
            true ->
                Fails = B#backend.fail_count + 1,
                %% Mark down after 3 consecutive failures
                NewStatus = if Fails >= 3 -> down; true -> up end,
                B#backend{
                    status = NewStatus,
                    fail_count = Fails,
                    total_requests = B#backend.total_requests + 1
                };
            false ->
                B
        end
    end, Backends),
    {noreply, State#state{backends = Updated}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal Functions
%%====================================================================

strip_trailing_slash(Url) ->
    case lists:reverse(Url) of
        "/" ++ Rest -> lists:reverse(Rest);
        _ -> Url
    end.

