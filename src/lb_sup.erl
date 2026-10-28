%%%-------------------------------------------------------------------
%%% @doc Load Balancer Root Supervisor
%%% Supervises backend_manager, request_queue, and http_gateway.
%%% @end
%%%-------------------------------------------------------------------
-module(lb_sup).
-behaviour(supervisor).

-export([start_link/3]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link(Backends, RatePerMin, ListenPort) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [Backends, RatePerMin, ListenPort]).

init([Backends, RatePerMin, ListenPort]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },

    ChildSpecs = [
        #{
            id => backend_manager,
            start => {backend_manager, start_link, [Backends]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [backend_manager]
        },
        #{
            id => request_queue,
            start => {request_queue, start_link, [RatePerMin]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [request_queue]
        },
        #{
            id => http_gateway,
            start => {http_gateway, start_link, [ListenPort]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [http_gateway]
        }
    ],

    {ok, {SupFlags, ChildSpecs}}.

