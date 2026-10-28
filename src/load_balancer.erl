-module(load_balancer).
-export([start/0, start/2, stop/0]).
-export([accept_loop/1, proxy_init/1, manager_loop/2]).

-define(DEFAULT_LISTEN_PORT, 8080).
-define(DEFAULT_BACKENDS, [{"127.0.0.1", 9001}, {"127.0.0.1", 9002}, {"127.0.0.1", 9003}]).
-define(CONNECT_TIMEOUT, 3000).

%% ====================================================================
%% Public API
%% ====================================================================

%% @doc Start load balancer with default configuration (port 8080 and 3 backends)
start() ->
    start(?DEFAULT_LISTEN_PORT, ?DEFAULT_BACKENDS).

%% @doc Start load balancer with custom ListenPort and Backends list: [{"IP", Port}, ...]
start(ListenPort, Backends) ->
    case whereis(lb_manager) of
        undefined -> ok;
        OldPid ->
            exit(OldPid, kill),
            timer:sleep(100)
    end,
    ManagerPid = spawn(?MODULE, manager_loop, [Backends, 1]),
    register(lb_manager, ManagerPid),

    case gen_tcp:listen(ListenPort, [binary, {packet, 0}, {active, false}, {reuseaddr, true}]) of
        {ok, ListenSocket} ->
            io:format("~n====================================================~n"),
            io:format(" [Load Balancer] Started successfully!~n"),
            io:format(" [Load Balancer] Listening on port: ~p~n", [ListenPort]),
            io:format(" [Load Balancer] Configured Backends (Round-Robin):~n"),
            lists:foreach(fun({Host, Port}) ->
                io:format("   --> ~s:~p~n", [Host, Port])
            end, Backends),
            io:format("====================================================~n~n"),
            spawn(fun() -> accept_loop(ListenSocket) end),
            {ok, ManagerPid};
        {error, Reason} ->
            io:format("[Load Balancer] Failed to bind on port ~p: ~p~n", [ListenPort, Reason]),
            unregister(lb_manager),
            exit(ManagerPid, kill),
            {error, Reason}
    end.

%% @doc Stop the load balancer manager
stop() ->
    case whereis(lb_manager) of
        undefined ->
            io:format("[Load Balancer] Already stopped.~n");
        Pid ->
            exit(Pid, normal),
            io:format("[Load Balancer] Manager process stopped.~n")
    end.

%% ====================================================================
%% State Manager for Round-Robin Backend Selection
%% ====================================================================

manager_loop(Backends, Index) ->
    receive
        {get_backend, From} ->
            case Backends of
                [] ->
                    From ! {backend, {error, no_backends}},
                    manager_loop(Backends, Index);
                _ ->
                    NumBackends = length(Backends),
                    SafeIndex = ((Index - 1) rem NumBackends) + 1,
                    SelectedBackend = lists:nth(SafeIndex, Backends),
                    NextIndex = (Index rem NumBackends) + 1,
                    From ! {backend, SelectedBackend},
                    manager_loop(Backends, NextIndex)
            end;
        stop ->
            ok
    end.

get_next_backend() ->
    lb_manager ! {get_backend, self()},
    receive
        {backend, {error, Reason}} -> {error, Reason};
        {backend, Backend} -> {ok, Backend}
    after 2000 ->
        {error, timeout}
    end.

%% ====================================================================
%% Connection Acceptor Loop
%% ====================================================================

accept_loop(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, ClientSocket} ->
            WorkerPid = spawn(?MODULE, proxy_init, [ClientSocket]),
            case gen_tcp:controlling_process(ClientSocket, WorkerPid) of
                ok ->
                    WorkerPid ! socket_ready;
                {error, _Reason} ->
                    gen_tcp:close(ClientSocket)
            end,
            accept_loop(ListenSocket);
        {error, closed} ->
            io:format("[Acceptor] Listen socket closed.~n");
        {error, Reason} ->
            io:format("[Acceptor] Accept error: ~p~n", [Reason]),
            accept_loop(ListenSocket)
    end.

%% ====================================================================
%% Proxy Worker Process
%% ====================================================================

proxy_init(ClientSocket) ->
    receive
        socket_ready ->
            %% Try up to 3 times to find an active backend if any backend is down
            connect_to_backend_and_proxy(ClientSocket, 3)
    after 5000 ->
        gen_tcp:close(ClientSocket)
    end.

connect_to_backend_and_proxy(ClientSocket, RetriesLeft) when RetriesLeft > 0 ->
    case get_next_backend() of
        {ok, {Host, Port}} ->
            case gen_tcp:connect(Host, Port, [binary, {packet, 0}, {active, true}], ?CONNECT_TIMEOUT) of
                {ok, BackendSocket} ->
                    io:format("[Proxy] Routing incoming client -> ~s:~p~n", [Host, Port]),
                    inet:setopts(ClientSocket, [binary, {packet, 0}, {active, true}]),
                    proxy_loop(ClientSocket, BackendSocket);
                {error, Reason} ->
                    io:format("[Proxy] Backend ~s:~p failed (~p). Trying next...~n", [Host, Port, Reason]),
                    connect_to_backend_and_proxy(ClientSocket, RetriesLeft - 1)
            end;
        {error, Reason} ->
            io:format("[Proxy] Backend selection error: ~p. Trying next...~n", [Reason]),
            connect_to_backend_and_proxy(ClientSocket, RetriesLeft - 1)
    end;
connect_to_backend_and_proxy(ClientSocket, 0) ->
    io:format("[Proxy] All backends failed. Closing client connection.~n"),
    gen_tcp:close(ClientSocket).

%% ====================================================================
%% Bidirectional Relay Loop
%% ====================================================================

proxy_loop(ClientSocket, BackendSocket) ->
    receive
        %% Client -> Backend
        {tcp, ClientSocket, Data} ->
            case gen_tcp:send(BackendSocket, Data) of
                ok -> proxy_loop(ClientSocket, BackendSocket);
                {error, _} ->
                    gen_tcp:close(ClientSocket),
                    gen_tcp:close(BackendSocket)
            end;
        %% Backend -> Client
        {tcp, BackendSocket, Data} ->
            case gen_tcp:send(ClientSocket, Data) of
                ok -> proxy_loop(ClientSocket, BackendSocket);
                {error, _} ->
                    gen_tcp:close(ClientSocket),
                    gen_tcp:close(BackendSocket)
            end;
        %% Connection Closed Events
        {tcp_closed, ClientSocket} ->
            gen_tcp:close(BackendSocket);
        {tcp_closed, BackendSocket} ->
            gen_tcp:close(ClientSocket);
        %% Connection Errors
        {tcp_error, _, _Reason} ->
            gen_tcp:close(ClientSocket),
            gen_tcp:close(BackendSocket)
    end.
