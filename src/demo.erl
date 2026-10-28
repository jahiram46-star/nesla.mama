-module(demo).
-export([run/0]).

%% @doc Helper to start all backend servers and load balancer together for testing
run() ->
    io:format("Starting Backend Servers...~n"),
    backend_server:start_all(),
    timer:sleep(500),
    io:format("Starting Load Balancer...~n"),
    load_balancer:start(),
    io:format("~nTest with:~n  curl http://localhost:8080~n~n").
