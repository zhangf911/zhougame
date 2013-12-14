%% Author: eric.yutao
%% Created: 2013-11-29
%% Description: TODO: Add description to server_tool
-module(server_tool).

%%
%% Include files
%%

%%
%% Exported Functions
%%
-export([run/0, print_tool/0]).

-compile(export_all).

%%
%% API Functions
%%
run() ->
    applicationex:force_start(),
    check_line_run(),
    check_map_run(),
%%     check_db_run(),
%%     check_cache_run(),
    check_gate_run(),
%%     NodeName = node_util:get_node_name_by_node(),
%%     AppName = list_to_atom(NodeName++"_app"),
%%     debug:info("*************Server tool ~p~n", [{?MODULE, node(), AppName}]),
%%     applicationex:start(AppName),
	ok.

print_tool() ->
	ok.

test() ->
    io:format("Error1111 Test ~p~n", [?MODULE]).


%%
%% Local Functions
%%
check_map_run() ->
	Node = node_util:get_node_sname(node()),
	case node_util:check_snode_match(map, Node) of
		true -> map_app:start();
		_ -> ignore
	end.

check_db_run() ->
	Node = node_util:get_node_sname(node()),
	case node_util:check_snode_match(db, Node) of
		true -> db_app:start();
		_ -> ignore
	end.

check_line_run() ->
	Node = node_util:get_node_sname(node()),
	case node_util:check_snode_match(line, Node) of
		true -> line_app:start();
		_ -> ignore
	end.

check_gate_run() ->
	Node = node_util:get_node_sname(node()),
	case node_util:check_snode_match(gate, Node) of
		true -> gate_app:start();
		_ -> ignore
	end.

check_cache_run() ->
	Node = node_util:get_node_sname(node()),
	case node_util:check_snode_match(cache, Node) of
		true -> map_app:start();
		_ -> ignore
	end.

check_gm_run() ->
	Node = node_util:get_node_sname(node()),
	case node_util:check_snode_match(gm, Node) of
		true -> map_app:start();
		_ -> ignore
	end.









