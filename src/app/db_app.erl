%% Author: Eric.yutao
%% Created: 2013-12-7
%% Description: TODO: Add description to db_app
-module(db_app).

-behaviour(application).
%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------

%% --------------------------------------------------------------------
%% Behavioural exports
%% --------------------------------------------------------------------
-export([
	 start/2,
     start/0,
	 stop/1
        ]).

%% --------------------------------------------------------------------
%% Internal exports
%% --------------------------------------------------------------------
-export([]).

%% --------------------------------------------------------------------
%% Macros
%% --------------------------------------------------------------------

%% --------------------------------------------------------------------
%% Records
%% --------------------------------------------------------------------

%% --------------------------------------------------------------------
%% API Functions
%% --------------------------------------------------------------------


%% ====================================================================!
%% External functions
%% ====================================================================!
%% --------------------------------------------------------------------
%% Func: start/2
%% Returns: {ok, Pid}        |
%%          {ok, Pid, State} |
%%          {error, Reason}
%% --------------------------------------------------------------------
start(Type, StartArgs) ->
    case app_util:get_argument("-line") of
        [] -> slogger:msg("Error in Gate app ~p~n", [?MODULE]);
        [_Center|Rest] ->
            debug:info("************** Gate app ~p~n", [""]),
            debug:log_file("../log/gate.log"),
            debug:error("Test for log file~n"),
            ping_center:wait_all_nodes_connect(true),
            %% MySQL need be treated as application
            erlmysql_app:start(),
            case gate_sup:start_link(StartArgs) of
                {ok, Pid} ->
                    {ok, Pid};
                Error ->
                    Error
            end
    end.

start() ->
    applicationex:start(?MODULE).

%% --------------------------------------------------------------------
%% Func: stop/1
%% Returns: any
%% --------------------------------------------------------------------
stop(State) ->
    ok.

%% ====================================================================
%% Internal functions
%% ====================================================================
