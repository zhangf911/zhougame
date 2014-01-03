%%% File    : mysql.erl
%%% Author  : Magnus Ahltorp <ahltorp@nada.kth.se>
%%% Descrip.: MySQL client.
%%%
%%% Created :  4 Aug 2005 by Magnus Ahltorp <ahltorp@nada.kth.se>
%%%
%%% Copyright (c) 2001-2004 Kungliga Tekniska H�gskolan
%%% See the file COPYING
%%%
%%% Modified: 9/12/2006 by Yariv Sadan <yarivvv@gmail.com>
%%% Note: Added support for prepared statements,
%%% transactions, better connection pooling, more efficient logging
%%% and made other internal enhancements.
%%%
%%% Modified: 9/23/2006 Rewrote the transaction handling code to
%%% provide a simpler, Mnesia-style transaction interface. Also,
%%% moved much of the prepared statement handling code to mysql_conn.erl
%%% and added versioning to prepared statements.
%%% 
%%%
%%% Usage:
%%%
%%%
%%% Call one of the start-functions before any call to fetch/2
%%%
%%%   start_link(PoolId, Host, User, Password, Database)
%%%   start_link(PoolId, Host, Port, User, Password, Database)
%%%   start_link(PoolId, Host, User, Password, Database, LogFun)
%%%   start_link(PoolId, Host, Port, User, Password, Database, LogFun)
%%%
%%% (These functions also have non-linking coutnerparts.)
%%%
%%% PoolId is a connection pool identifier. If you want to have more
%%% than one connection to a server (or a set of MySQL replicas),
%%% add more with
%%%
%%%   connect(PoolId, Host, Port, User, Password, Database, Reconnect)
%%%
%%% use 'undefined' as Port to get default MySQL port number (3306).
%%% MySQL querys will be sent in a per-PoolId round-robin fashion.
%%% Set Reconnect to 'true' if you want the dispatcher to try and
%%% open a new connection, should this one die.
%%%
%%% When you have a mysql_dispatcher running, this is how you make a
%%% query :
%%%
%%%   fetch(PoolId, "select * from hello") -> Result
%%%     Result = {data, MySQLRes} | {updated, MySQLRes} |
%%%              {error, MySQLRes}
%%%
%%% Actual data can be extracted from MySQLRes by calling the following API
%%% functions:
%%%     - on data received:
%%%          FieldInfo = mysql:get_result_field_info(MysqlRes)
%%%          AllRows   = mysql:get_result_rows(MysqlRes)
%%%         with FieldInfo = list() of {Table, Field, Length, Name}
%%%          and AllRows   = list() of list() representing records
%%%     - on update:
%%%          Affected  = mysql:get_result_affected_rows(MysqlRes)
%%%         with Affected  = integer()
%%%     - on error:
%%%          Reason    = mysql:get_result_reason(MysqlRes)
%%%         with Reason    = string()
%%% 
%%% If you just want a single MySQL connection, or want to manage your
%%% connections yourself, you can use the mysql_conn module as a
%%% stand-alone single MySQL connection. See the comment at the top of
%%% mysql_conn.erl.

-module(mysql).
-behaviour(gen_server).


%% @type mysql_result() = term()
%% @type query_result = {data, mysql_result()} | {updated, mysql_result()} |
%%   {error, mysql_result()}


%% External exports
-export([start_link/6,
	 start_link/7,
	 start_link/8,
	 start_link/9,

	 start/6,
	 start/7,
	 start/8,
	 start/9,

	 connect/1,
	 connect/8,
	 connect/9,
	 connect/10,

	 fetch/1,
	 fetch/3,
	 fetch/4,
	 
	 prepare/3,
	 execute/1,
	 execute/2,
	 execute/3,
	 execute/4,
	 unprepare/2,
	 get_prepared/1,
	 get_prepared/2,

	 transaction/3,
	 transaction/4,

	 get_result_field_info/1,
	 get_result_rows/1,
	 get_result_affected_rows/1,
	 get_result_reason/1,

	 encode/1,
	 encode/2,
	 asciz_binary/2,
	  
	 quote/1
	]).

%% Internal exports - just for mysql_* modules
-export([log/4
	]).

%% Internal exports - gen_server callbacks
-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3
	]).

%% Records
-include("mysql.hrl").

-record(conn, {
	  server_name,	%% atom(), the server name
	  pool_id,      %% atom(), the pool's id
	  pid,          %% pid(), mysql_conn process	 
	  reconnect,	%% true | false, should mysql_dispatcher try
                        %% to reconnect if this connection dies?
	  host,		%% string()
	  port,		%% integer()
	  user,		%% string()
	  password,	%% string()
	  database,	%% string()
	  encoding
	 }).

-record(state, {
	  %% gb_tree mapping connection
	  %% pool id to a connection pool tuple
	  conn_pools = gb_trees:empty(), 
	                

	  %% gb_tree mapping connection Pid
	  %% to pool id
	  pids_pools = gb_trees:empty(), 
	                                 
	  %% function for logging,
	  log_fun,	


	  %% maps names to {Statement::binary(), Version::integer()} values
	  prepares = gb_trees:empty()
	 }).

%% Macros
-define(SERVER, mysql_dispatcher).
-define(STATE_VAR, mysql_connection_state).
-define(CONNECT_TIMEOUT, 20000).
-define(LOCAL_FILES, 128).
-define(PORT, 3306).

%% used for debugging
-define(L(Msg), io:format("~p:~b ~p ~n", [?MODULE, ?LINE, Msg])).

%% Log messages are designed to instantiated lazily only if the logging level
%% permits a log message to be logged
-define(Log(LogFun,Level,Msg),
	LogFun(?MODULE,?LINE,Level,fun()-> {Msg,[]} end)).
-define(Log2(LogFun,Level,Msg,Params),
	LogFun(?MODULE,?LINE,Level,fun()-> {Msg,Params} end)).
			     

log(Module, Line, _Level, FormatFun) ->
    {Format, Arguments} = FormatFun(),
    io:format("~w:~b: "++ Format ++ "~n", [Module, Line] ++ Arguments).


%% External functions

%% @doc Starts the MySQL client gen_server process.
%%
%% The Port and LogFun parameters are optional.
%%
%% @spec start_link(PoolId::atom(), Host::string(), Port::integer(),
%%   Username::string(), Password::string(), Database::string(),
%%   LogFun::undefined | function() of arity 4) ->
%%     {ok, Pid} | ignore | {error, Err}
%% start_link(PoolId, Host, User, Password, Database) ->
%%     start_link(PoolId, Host, ?PORT, User, Password, Database).
%% 
%% start_link(PoolId, Host, Port, User, Password, Database) ->
%%     start_link(PoolId, Host, Port, User, Password, Database, undefined,
%% 	       undefined).
%% 
%% start_link(PoolId, Host, undefined, User, Password, Database, LogFun) ->
%%     start_link(PoolId, Host, ?PORT, User, Password, Database, LogFun,
%% 	       undefined);
%% start_link(PoolId, Host, Port, User, Password, Database, LogFun) ->
%%     start_link(PoolId, Host, Port, User, Password, Database, LogFun,
%% 	       undefined).
%% 
%% start_link(PoolId, Host, undefined, User, Password, Database, LogFun,
%% 	   Encoding) ->
%%     start1(PoolId, Host, ?PORT, User, Password, Database, LogFun, Encoding,
%% 	   start_link);
%% start_link(PoolId, Host, Port, User, Password, Database, LogFun, Encoding) ->
%%     start1(PoolId, Host, Port, User, Password, Database, LogFun, Encoding,
%% 	   start_link).


%% New start_link functions,add a ServerName argument 
start_link(ServerName, PoolId, Host, User, Password, Database) ->
    start_link(ServerName, PoolId, Host, ?PORT, User, Password, Database).

start_link(ServerName, PoolId, Host, Port, User, Password, Database) ->
    start_link(ServerName, PoolId, Host, Port, User, Password, Database, undefined,
	       undefined).

start_link(ServerName, PoolId, Host, undefined, User, Password, Database, LogFun) ->
    start_link(ServerName, PoolId, Host, ?PORT, User, Password, Database, LogFun,
	       undefined);
start_link(ServerName, PoolId, Host, Port, User, Password, Database, LogFun) ->
    start_link(ServerName, PoolId, Host, Port, User, Password, Database, LogFun,
	       undefined).

start_link(ServerName, PoolId, Host, undefined, User, Password, Database, LogFun,
	   Encoding) ->
    start1(ServerName, PoolId, Host, ?PORT, User, Password, Database, LogFun, Encoding,
	   start_link);
start_link(ServerName, PoolId, Host, Port, User, Password, Database, LogFun, Encoding) ->
    start1(ServerName, PoolId, Host, Port, User, Password, Database, LogFun, Encoding,
	   start_link).


%% @doc These functions are similar to their start_link counterparts,
%% but they call gen_server:start() instead of gen_server:start_link()
%% start(PoolId, Host, User, Password, Database) ->
%%     start(PoolId, Host, ?PORT, User, Password, Database).
%% 
%% start(PoolId, Host, Port, User, Password, Database) ->
%%     start(PoolId, Host, Port, User, Password, Database, undefined).
%% 
%% start(PoolId, Host, undefined, User, Password, Database, LogFun) ->
%%     start(PoolId, Host, ?PORT, User, Password, Database, LogFun);
%% start(PoolId, Host, Port, User, Password, Database, LogFun) ->
%%     start(PoolId, Host, Port, User, Password, Database, LogFun, undefined).
%% 
%% start(PoolId, Host, undefined, User, Password, Database, LogFun, Encoding) ->
%%     start1(PoolId, Host, ?PORT, User, Password, Database, LogFun, Encoding,
%% 	   start);
%% start(PoolId, Host, Port, User, Password, Database, LogFun, Encoding) ->
%%     start1(PoolId, Host, Port, User, Password, Database, LogFun, Encoding,
%% 	   start).

start(ServerName, PoolId, Host, User, Password, Database) ->
    start(ServerName, PoolId, Host, ?PORT, User, Password, Database).

start(ServerName, PoolId, Host, Port, User, Password, Database) ->
    start(ServerName, PoolId, Host, Port, User, Password, Database, undefined).

start(ServerName, PoolId, Host, undefined, User, Password, Database, LogFun) ->
    start(ServerName, PoolId, Host, ?PORT, User, Password, Database, LogFun);
start(ServerName, PoolId, Host, Port, User, Password, Database, LogFun) ->
    start(ServerName, PoolId, Host, Port, User, Password, Database, LogFun, undefined).

start(ServerName, PoolId, Host, undefined, User, Password, Database, LogFun, Encoding) ->
    start1(ServerName, PoolId, Host, ?PORT, User, Password, Database, LogFun, Encoding,
	   start);
start(ServerName, PoolId, Host, Port, User, Password, Database, LogFun, Encoding) ->
    start1(ServerName, PoolId, Host, Port, User, Password, Database, LogFun, Encoding,
	   start).

%% start1(PoolId, Host, Port, User, Password, Database, LogFun, Encoding,
%%        StartFunc) ->
%%     crypto:start(),
%%     gen_server:StartFunc(
%%       {local, ?SERVER}, ?MODULE,
%%       [PoolId, Host, Port, User, Password, Database, LogFun, Encoding], []).

start1(ServerName, PoolId, Host, Port, User, Password, Database, LogFun, Encoding,
       StartFunc) ->
    crypto:start(),
    gen_server:StartFunc(
      {local, ServerName}, ?MODULE,
      [ServerName, PoolId, Host, Port, User, Password, Database, LogFun, Encoding], []).


%% @equiv connect(PoolId, Host, Port, User, Password, Database, Encoding,
%%	   Reconnect, true)
connect([ServerName, PoolId, Host, Port, User, Password, Database, Reconnect]) ->
	connect(ServerName, PoolId, Host, Port, User, Password, Database, 'utf8', Reconnect).

connect(ServerName, PoolId, Host, Port, User, Password, Database, Encoding, Reconnect) ->
    connect(ServerName, PoolId, Host, Port, User, Password, Database, Encoding,
	    Reconnect, true).

%% @doc Starts a MySQL connection and, if successful, add it to the
%%   connection pool in the dispatcher.
%%
%% @spec: connect(PoolId::atom(), Host::string(), Port::integer() | undefined,
%%    User::string(), Password::string(), Database::string(),
%%    Encoding::string(), Reconnect::bool(), LinkConnection::bool()) ->
%%      {ok, ConnPid} | {error, Reason}
connect(ServerName, PoolId, Host, Port, User, Password, Database, Encoding, Reconnect,
       LinkConnection) ->
    Port1 = if Port == undefined -> ?PORT; true -> Port end,
    Fun = if LinkConnection ->
		  fun mysql_conn:start_link/8;
	     true ->
		  fun mysql_conn:start/8
	  end,

   {ok, LogFun} = gen_server:call(ServerName, get_logfun),
    case Fun(Host, Port1, User, Password, Database, LogFun,
	     Encoding, PoolId) of
	{ok, ConnPid} ->
	    Conn = new_conn(ServerName, PoolId, ConnPid, Reconnect, Host, Port1, User,
			    Password, Database, Encoding),
	    case gen_server:call(
		   ServerName, {add_conn, Conn}) of
		ok ->
		    {ok, ConnPid};
		Res ->
		    Res
	    end;
	Err->
	    Err
    end.

refresh_connect(ServerName, PoolId, Host, Port, User, Password, Database, Encoding, Reconnect,
       LinkConnection, OldState) ->
    Port1 = if Port == undefined -> ?PORT; true -> Port end,
    Fun = if LinkConnection ->
		  fun mysql_conn:start_link/8;
	     true ->
		  fun mysql_conn:start/8
	  end,

%%    {ok, LogFun} = gen_server:call(ServerName, get_logfun),
	LogFun = OldState#state.log_fun,
    case Fun(Host, Port1, User, Password, Database, LogFun,
	     Encoding, PoolId) of
	{ok, ConnPid} ->
	    Conn = new_conn(ServerName, PoolId, ConnPid, Reconnect, Host, Port1, User,
			    Password, Database, Encoding),
		NewState = add_conn(Conn, OldState),
		{ok, ConnPid, NewState};
%% 	    case gen_server:call(
%% 		   ServerName, {add_conn, Conn}) of
%% 		ok ->
%% 		    {ok, ConnPid};
%% 		Res ->
%% 		    Res
%% 	    end;
	Err->
	    Err
    end.

new_conn(ServerName, PoolId, ConnPid, Reconnect, Host, Port, User, Password, Database,
	 Encoding) ->
    case Reconnect of
	true ->
	    #conn{server_name = ServerName,
		  pool_id = PoolId,
		  pid = ConnPid,
		  reconnect = true,
		  host = Host,
		  port = Port,
		  user = User,
		  password = Password,
		  database = Database,
		  encoding = Encoding
		 };
	false ->                        
	    #conn{pool_id = PoolId,
		  pid = ConnPid,
		  reconnect = false}
    end.

do_refresh_all(ServerName) ->
	gen_server:call(ServerName, {refresh, ServerName}).

%% @doc Fetch a query inside a transaction.
%%
%% @spec fetch(Query::iolist()) -> query_result()
fetch(Query) ->
    case get(?STATE_VAR) of
	undefined ->
	    {error, not_in_transaction};
	State ->
	    mysql_conn:fetch_local(State, Query)
    end.

%% @doc Send a query to a connection from the connection pool and wait
%%   for the result. If this function is called inside a transaction,
%%   the PoolId parameter is ignored.
%%
%% @spec fetch(PoolId::atom(), Query::iolist(), Timeout::integer()) ->
%%   query_result()
fetch(ServerName, PoolId, Query) ->
    fetch(ServerName, PoolId, Query, undefined).

fetch(ServerName, PoolId, Query, Timeout) -> 
    case get(?STATE_VAR) of
	undefined ->
	    call_server(ServerName, {fetch, PoolId, Query}, Timeout);
	State ->
	    mysql_conn:fetch_local(State, Query)
    end.


%% @doc Register a prepared statement with the dispatcher. This call does not
%%   prepare the statement in any connections. The statement is prepared
%%   lazily in each connection when it is told to execute the statement.
%%   If the Name parameter matches the name of a statement that has
%%   already been registered, the version of the statement is incremented
%%   and all connections that have already prepared the statement will
%%   prepare it again with the newest version.
%%
%% @spec prepare(Name::atom(), Query::iolist()) -> ok
prepare(ServerName, Name, Query) ->
    gen_server:cast(ServerName, {prepare, Name, Query}).

%% @doc Unregister a statement that has previously been register with
%%   the dispatcher. All calls to execute() with the given statement
%%   will fail once the statement is unprepared. If the statement hasn't
%%   been prepared, nothing happens.
%%
%% @spec unprepare(Name::atom()) -> ok
unprepare(ServerName, Name) ->
    gen_server:cast(ServerName, {unprepare, Name}).

%% @doc Get the prepared statement with the given name.
%%
%%  This function is called from mysql_conn when the connection is
%%  told to execute a prepared statement it has not yet prepared, or
%%  when it is told to execute a statement inside a transaction and
%%  it's not sure that it has the latest version of the statement.
%%
%%  If the latest version of the prepared statement matches the Version
%%  parameter, the return value is {ok, latest}. This saves the cost
%%  of sending the query when the connection already has the latest version.
%%
%% @spec get_prepared(Name::atom(), Version::integer()) ->
%%   {ok, latest} | {ok, Statement::binary()} | {error, Err}
get_prepared(ServerName) ->
	get_prepared(ServerName, undefined).
get_prepared(ServerName, Name) ->
    get_prepared(ServerName, Name, undefined).
get_prepared(ServerName, Name, Version) ->
    gen_server:call(ServerName, {get_prepared, Name, Version}).


%% @doc Execute a query inside a transaction.
%%
%% @spec execute(Name::atom, Params::[term()]) -> mysql_result()
execute(Name) ->
    execute(Name, []).

execute(Name, Params) when is_atom(Name), is_list(Params) ->
    case get(?STATE_VAR) of
	undefined ->
	    {error, not_in_transaction};
	State ->
	    mysql_conn:execute_local(State, Name, Params)
    end.

%% @doc Execute a query in the connection pool identified by
%% PoolId. This function optionally accepts a list of parameters to pass
%% to the prepared statement and a Timeout parameter.
%% If this function is called inside a transaction, the PoolId paramter is
%% ignored.
%%
%% @spec execute(PoolId::atom(), Name::atom(), Params::[term()],
%%   Timeout::integer()) -> mysql_result()
execute(ServerName, PoolId, Name) when is_atom(PoolId), is_atom(Name) ->
    execute(ServerName, PoolId, Name, []).

execute(ServerName, PoolId, Name, Timeout) when is_integer(Timeout) ->
    execute(ServerName, PoolId, Name, [], Timeout);

execute(ServerName, PoolId, Name, Params) when is_list(Params) ->
    execute(ServerName, PoolId, Name, Params, undefined).

execute(ServerName, PoolId, Name, Params, Timeout) ->
    case get(?STATE_VAR) of
	undefined ->
	    call_server(ServerName, {execute, PoolId, Name, Params}, Timeout);
	State ->
	      case mysql_conn:execute_local(State, Name, Params) of
		  {ok, Res, NewState} ->
		      put(?STATE_VAR, NewState),
		      Res;
		  Err ->
		      Err
	      end
    end.

%% @doc Execute a transaction in a connection belonging to the connection pool.
%% Fun is a function containing a sequence of calls to fetch() and/or
%% execute().
%% If an error occurs, or if the function does any of the following:
%%
%% - throw(error)
%% - throw({error, Err})
%% - return error
%% - return {error, Err}
%% - exit(Reason)
%%
%% the transaction is automatically rolled back.
%%
%% @spec transaction(PoolId::atom(), Fun::function()) ->
%%   {atomic, Result} | {aborted, {Reason, {rollback_result, Result}}}
transaction(ServerName, PoolId, Fun) ->
    transaction(ServerName, PoolId, Fun, undefined).

transaction(ServerName, PoolId, Fun, Timeout) ->
    case get(?STATE_VAR) of
	undefined ->
	    call_server(ServerName, {transaction, PoolId, Fun}, Timeout);
	State ->
	    case mysql_conn:get_pool_id(State) of
		PoolId ->
		    case catch Fun() of
			error = Err -> throw(Err);
			{error, _} = Err -> throw(Err);
			{'EXIT', _} = Err -> throw(Err);
			Other -> {atomic, Other}
		    end;
		_Other ->
		    call_server(ServerName, {transaction, PoolId, Fun}, Timeout)
	    end
    end.

%% @doc Extract the FieldInfo from MySQL Result on data received.
%%
%% @spec get_result_field_info(MySQLRes::mysql_result()) ->
%%   [{Table, Field, Length, Name}]
get_result_field_info(#mysql_result{fieldinfo = FieldInfo}) ->
    FieldInfo.

%% @doc Extract the Rows from MySQL Result on data received
%% 
%% @spec get_result_rows(MySQLRes::mysql_result()) -> [Row::list()]
get_result_rows(#mysql_result{rows=AllRows}) ->
    AllRows.

%% @doc Extract the Rows from MySQL Result on update
%%
%% @spec get_result_affected_rows(MySQLRes::mysql_result()) ->
%%           AffectedRows::integer()
get_result_affected_rows(#mysql_result{affectedrows=AffectedRows}) ->
    AffectedRows.

%% @doc Extract the error Reason from MySQL Result on error
%%
%% @spec get_result_reason(MySQLRes::mysql_result()) ->
%%    Reason::string()
get_result_reason(#mysql_result{error=Reason}) ->
    Reason.


connect(ServerName, PoolId, Host, undefined, User, Password, Database, Reconnect) ->
    connect(ServerName, PoolId, Host, ?PORT, User, Password, Database, undefined,
	    Reconnect).

%% gen_server callbacks

init([ServerName, PoolId, Host, Port, User, Password, Database, LogFun, Encoding]) ->
    LogFun1 = if LogFun == undefined -> fun log/4; true -> LogFun end,
    case mysql_conn:start(Host, Port, User, Password, Database, LogFun1,
			  Encoding, PoolId) of
	{ok, ConnPid} ->
	    Conn = new_conn(ServerName, PoolId, ConnPid, true, Host, Port, User, Password,
			    Database, Encoding),
	    State = #state{log_fun = LogFun1},
	    {ok, add_conn(Conn, State)};
	{error, Reason} ->
	    ?Log(LogFun1, error,
		 "failed starting first MySQL connection handler, "
		 "exiting"),
	    {stop, {error, Reason}}
    end.

handle_call({fetch, PoolId, Query}, From, State) ->
    fetch_queries(PoolId, From, State, [Query]);

handle_call({get_prepared, Name, Version}, _From, State) ->
    case gb_trees:lookup(Name, State#state.prepares) of
	none ->
	    {reply, {error, {undefined, Name}}, State};
	{value, {_StmtBin, Version1}} when Version1 == Version ->
	    {reply, {ok, latest}, State};
	{value, Stmt} ->
	    {reply, {ok, Stmt}, State}
    end;

handle_call({execute, PoolId, Name, Params}, From, State) ->
    with_next_conn(
      PoolId, State,
      fun(Conn, State1) ->
	      case gb_trees:lookup(Name, State1#state.prepares) of
		  none ->
		      {reply, {error, {no_such_statement, Name}}, State1};
		  {value, {_Stmt, Version}} ->
		      mysql_conn:execute(Conn#conn.pid, Name,
					 Version, Params, From),
		      {noreply, State1}
	      end
      end);

handle_call({transaction, PoolId, Fun}, From, State) ->
    with_next_conn(
      PoolId, State,
      fun(Conn, State1) ->
	      mysql_conn:transaction(Conn#conn.pid, Fun, From),
	      {noreply, State1}
      end);

handle_call({add_conn, Conn}, _From, State) ->
    NewState = add_conn(Conn, State),
%%     {PoolId, ConnPid} = {Conn#conn.pool_id, Conn#conn.pid},
%%     LogFun = State#state.log_fun,
%%     ?Log2(LogFun, normal,
%% 	  "added connection with id '~p' (pid ~p) to my list",
%% 	  [PoolId, ConnPid]),
    {reply, ok, NewState};

handle_call(get_logfun, _From, State) ->
    {reply, {ok, State#state.log_fun}, State}.

handle_cast({prepare, Name, Stmt}, State) ->
    LogFun = State#state.log_fun,
    Version1 =
	case gb_trees:lookup(Name, State#state.prepares) of
	    {value, {_Stmt, Version}} ->
		Version + 1;
	    none ->
		1
	end,
    ?Log2(LogFun, debug,
	"received prepare/2: ~p (ver ~p) ~p", [Name, Version1, Stmt]),
    {noreply, State#state{prepares =
			  gb_trees:enter(Name, {Stmt, Version1},
					  State#state.prepares)}};

handle_cast({unprepare, Name}, State) ->
    LogFun = State#state.log_fun,
    ?Log2(LogFun, debug, "received unprepare/1: ~p", [Name]),
    State1 =
	case gb_trees:lookup(Name, State#state.prepares) of
	    none ->
		?Log2(LogFun, warn, "trying to unprepare a non-existing "
		      "statement: ~p", [Name]),
		State;
	    {value, _Stmt} ->
		State#state{prepares =
			    gb_trees:delete(Name, State#state.prepares)}
	end,
    {noreply, State1}.

%% Called when a connection to the database has been lost. If
%% The 'reconnect' flag was set to true for the connection, we attempt
%% to establish a new connection to the database.
handle_info({'DOWN', _MonitorRef, process, Pid, Info}, State) ->
    LogFun = State#state.log_fun,
    case remove_conn(Pid, State) of
	{ok, Conn, NewState} ->
	    LogLevel = case Info of
			   normal -> normal;
			   _ -> error
		       end,
	    ?Log2(LogFun, LogLevel,
		"connection pid ~p exited : ~p", [Pid, Info]),
	    case Conn#conn.reconnect of
		true ->
		    start_reconnect(Conn, LogFun);
		false ->
		    ok
	    end,
	    {noreply, NewState};
	error ->
	    ?Log2(LogFun, error,
		  "received 'DOWN' signal from pid ~p not in my list", [Pid]),
	    {noreply, State}
    end.
    
terminate(Reason, State) ->
    LogFun = State#state.log_fun,
    LogLevel = case Reason of
		   normal -> debug;
		   _ -> error
	       end,
    ?Log2(LogFun, LogLevel, "terminating with reason: ~p", [Reason]),
    Reason.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Internal functions

fetch_queries(PoolId, From, State, QueryList) ->
    with_next_conn(
      PoolId, State,
      fun(Conn, State1) ->
	      Pid = Conn#conn.pid,
	      mysql_conn:fetch(Pid, QueryList, From),
	      {noreply, State1}
      end).

with_next_conn(PoolId, State, Fun) ->
    case get_next_conn(PoolId, State) of
	{ok, Conn, NewState} ->    
	    Fun(Conn, NewState);
	error ->
	    %% we have no active connection matching PoolId
	    {reply, {error, {no_connection_in_pool, PoolId}}, State}
    end.

call_server(ServerName, Msg, Timeout) ->
	%%修改第三个参数Timeout 为，增加超时时间设置(默认超时时间为5秒)
	Timeout1 = 20000,
    if Timeout == undefined ->
	    gen_server:call(ServerName, Msg, Timeout1);
       true ->
	    gen_server:call(ServerName, Msg, Timeout1)
    end.

add_conn(Conn, State) ->
    Pid = Conn#conn.pid,
    erlang:monitor(process, Conn#conn.pid),
    PoolId = Conn#conn.pool_id,
    ConnPools = State#state.conn_pools,
    NewPool = 
	case gb_trees:lookup(PoolId, ConnPools) of
	    none ->
		{[Conn],[]};
	    {value, {Unused, Used}} ->
		{[Conn | Unused], Used}
	end,
    State#state{conn_pools =
		gb_trees:enter(PoolId, NewPool,
			       ConnPools),
		pids_pools = gb_trees:enter(Pid, PoolId,
					    State#state.pids_pools)}.

remove_pid_from_list(Pid, Conns) ->
    lists:foldl(
      fun(OtherConn, {NewConns, undefined}) ->
	      if OtherConn#conn.pid == Pid ->
		      {NewConns, OtherConn};
		 true ->
		      {[OtherConn | NewConns], undefined}
	      end;
	 (OtherConn, {NewConns, FoundConn}) ->
	      {[OtherConn|NewConns], FoundConn}
      end, {[],undefined}, lists:reverse(Conns)).

remove_pid_from_lists(Pid, Conns1, Conns2) ->
    case remove_pid_from_list(Pid, Conns1) of
	{NewConns1, undefined} ->
	    {NewConns2, Conn} = remove_pid_from_list(Pid, Conns2),
	    {Conn, {NewConns1, NewConns2}};
	{NewConns1, Conn} ->
	    {Conn, {NewConns1, Conns2}}
    end.
    
remove_conn(Pid, State) ->
    PidsPools = State#state.pids_pools,
    case gb_trees:lookup(Pid, PidsPools) of
	none ->
	    error;
	{value, PoolId} ->
	    ConnPools = State#state.conn_pools,
	    case gb_trees:lookup(PoolId, ConnPools) of
		none ->
		    error;
		{value, {Unused, Used}} ->
		    {Conn, NewPool} = remove_pid_from_lists(Pid, Unused, Used),
		    NewConnPools = gb_trees:enter(PoolId, NewPool, ConnPools),
		    {ok, Conn, State#state{conn_pools = NewConnPools,
				     pids_pools =
				     gb_trees:delete(Pid, PidsPools)}}
	    end
    end.

get_next_conn(PoolId, State) ->
    ConnPools = State#state.conn_pools,
    case gb_trees:lookup(PoolId, ConnPools) of
	none ->
	    error;
	{value, {[],[]}} ->
	    error;
	%% We maintain 2 lists: one for unused connections and one for used
	%% connections. When we run out of unused connections, we recycle
	%% the list of used connections.
	{value, {[], Used}} ->
	    [Conn | Conns] = lists:reverse(Used),
	    {ok, Conn,
	     State#state{conn_pools =
			 gb_trees:enter(PoolId, {Conns, [Conn]}, ConnPools)}};
	{value, {[Conn|Unused], Used}} ->
	    {ok, Conn, State#state{
			 conn_pools =
			 gb_trees:enter(PoolId, {Unused, [Conn|Used]},
					ConnPools)}}
    end.

start_reconnect(Conn, LogFun) ->
    Pid = spawn(fun () ->
			reconnect_loop(Conn#conn{pid = undefined}, LogFun, 0)
		end),
    {PoolId, Host, Port} = {Conn#conn.pool_id, Conn#conn.host, Conn#conn.port},
    ?Log2(LogFun, debug,
	"started pid ~p to try and reconnect to ~p:~s:~p (replacing "
	"connection with pid ~p)",
	[Pid, PoolId, Host, Port, Conn#conn.pid]),
    ok.

reconnect_loop(Conn, LogFun, N) ->
    {ServerName, PoolId, Host, Port} = {Conn#conn.server_name, Conn#conn.pool_id, Conn#conn.host, Conn#conn.port},
    case connect(ServerName,
		 PoolId,
		 Host,
		 Port,
		 Conn#conn.user,
		 Conn#conn.password,
		 Conn#conn.database,
		 Conn#conn.encoding,
		 Conn#conn.reconnect) of
	{ok, ConnPid} ->
	    ?Log2(LogFun, debug,
		"managed to reconnect to ~p:~s:~p "
		"(connection pid ~p)", [PoolId, Host, Port, ConnPid]),
	    ok;
	{error, Reason} ->
	    %% log every once in a while
	    NewN = case N of
		       10 ->
			   ?Log2(LogFun, debug,
			       "reconnect: still unable to connect to "
			       "~p:~s:~p (~p)", [PoolId, Host, Port, Reason]),
			   0;
		       _ ->
			   N + 1
		   end,
	    %% sleep between every unsuccessful attempt
	    timer:sleep(5 * 1000),
	    reconnect_loop(Conn, LogFun, NewN)
    end.


%% @doc Encode a value so that it can be included safely in a MySQL query.
%%
%% @spec encode(Val::term(), AsBinary::bool()) ->
%%   string() | binary() | {error, Error}
encode(Val) ->
    encode(Val, false).
encode(Val, false) when Val == undefined; Val == null ->
    "null";
encode(Val, true) when Val == undefined; Val == null ->
    <<"null">>;
encode(Val, false) when is_binary(Val) ->
    binary_to_list(quote(Val));
encode(Val, true) when is_binary(Val) ->
    quote(Val);
encode(Val, true) ->
    list_to_binary(encode(Val,false));
encode(Val, false) when is_atom(Val) ->
    quote(atom_to_list(Val));
encode(Val, false) when is_list(Val) ->
    quote(Val);
encode(Val, false) when is_integer(Val) ->
    integer_to_list(Val);
encode(Val, false) when is_float(Val) ->
    [Res] = io_lib:format("~w", [Val]),
    Res;
encode({datetime, Val}, AsBinary) ->
    encode(Val, AsBinary);
encode({{Year, Month, Day}, {Hour, Minute, Second}}, false) ->
    Res = two_digits([Year, Month, Day, Hour, Minute, Second]),
    lists:flatten(Res);
encode({TimeType, Val}, AsBinary)
  when TimeType == 'date';
       TimeType == 'time' ->
    encode(Val, AsBinary);
encode({Time1, Time2, Time3}, false) ->
    Res = two_digits([Time1, Time2, Time3]),
    lists:flatten(Res);
encode(Val, _AsBinary) ->
    {error, {unrecognized_value, Val}}.

two_digits(Nums) when is_list(Nums) ->
    [two_digits(Num) || Num <- Nums];
two_digits(Num) ->
    [Str] = io_lib:format("~b", [Num]),
    case length(Str) of
	1 -> [$0 | Str];
	_ -> Str
    end.

%%  Quote a string or binary value so that it can be included safely in a
%%  MySQL query.
quote(String) when is_list(String) ->
    [39 | lists:reverse([39 | quote(String, [])])];	%% 39 is $'
quote(Bin) when is_binary(Bin) ->
    list_to_binary(quote(binary_to_list(Bin))).

quote([], Acc) ->
    Acc;
quote([0 | Rest], Acc) ->
    quote(Rest, [$0, $\\ | Acc]);
quote([10 | Rest], Acc) ->
    quote(Rest, [$n, $\\ | Acc]);
quote([13 | Rest], Acc) ->
    quote(Rest, [$r, $\\ | Acc]);
quote([$\\ | Rest], Acc) ->
    quote(Rest, [$\\ , $\\ | Acc]);
quote([39 | Rest], Acc) ->		%% 39 is $'
    quote(Rest, [39, $\\ | Acc]);	%% 39 is $'
quote([34 | Rest], Acc) ->		%% 34 is $"
    quote(Rest, [34, $\\ | Acc]);	%% 34 is $"
quote([26 | Rest], Acc) ->
    quote(Rest, [$Z, $\\ | Acc]);
quote([C | Rest], Acc) ->
    quote(Rest, [C | Acc]).


%% @doc Find the first zero-byte in Data and add everything before it
%%   to Acc, as a string.
%%
%% @spec asciz_binary(Data::binary(), Acc::list()) ->
%%   {NewList::list(), Rest::binary()}
asciz_binary(<<>>, Acc) ->
    {lists:reverse(Acc), <<>>};
asciz_binary(<<0:8, Rest/binary>>, Acc) ->
    {lists:reverse(Acc), Rest};
asciz_binary(<<C:8, Rest/binary>>, Acc) ->
    asciz_binary(Rest, [C | Acc]).







%% 
start_all_conn([ServerName, PoolId, LogFun], OldState) ->
	LogFun = fun erlmysql_sup:log/4,
	[PoolId, WHost, WPort, WUser, WPwd, WDB, WEncoding, WRunNode] = mysql_util:get_w_conf(),
	WriteArgs = [ServerName, PoolId, WHost, WPort, WUser, WPwd, WDB, LogFun, WEncoding],
	WNewState =
		case check_run_node(WRunNode) of
			true ->
				do_connect(write, WriteArgs, OldState);
			_ ->
				OldState
		end,
	[ReadPoolId, RHost, RPort, RUser, RPwd, RDB, REncoding, RRunNode] = mysql_util:get_r_conf(),
	ReadArgs = [ServerName, ReadPoolId, RHost, RPort, RUser, RPwd, RDB, LogFun, REncoding],
	RNewState =
		case check_run_node(RRunNode) of
			true ->
				do_connect(read, ReadArgs, WNewState);
			_ ->
				WNewState
		end,
	[LPoolId, LHost, LPort, LUser, LPwd, LDB, LEncoding, LRunNode] = mysql_util:get_w_conf(),
	LogArgs = [ServerName, LPoolId, LHost, LPort, LUser, LPwd, LDB, LEncoding, LRunNode],
	LNewState =
		case check_run_node(LRunNode) of
			true ->
				do_connect(log, LogArgs, RNewState);
			_ ->
				RNewState
		end,
	LNewState.


%%
%%@doc Check node run
%%@date:2014-1-3
%%	
check_run_node(RRunNode) when is_list(RRunNode) ->
	CheckFun = fun(Node, Acc) when not Acc ->
					   Index = string:str(atom_to_list(node()), atom_to_list(Node)),
					   if
						   Index =/= 0 ->
							   true;
						   true ->
							   Acc
					   end;
				  (_Node, Acc) ->
					   Acc
			   end,
	lists:foldl(CheckFun, false, RRunNode).


%%
%%@doc
%%@date:2014-1-3
%%
do_connect(write, [ServerName, PoolId, Host, Port, User, Pwd, DB, LogFun, Encoding]=Args, OldState) ->
	Size = mysql_util:get_w_pool_size() - 1,
	if
		Size =< 0 -> OldState;
		true -> do_connect(Size, Args, OldState)
	end;
do_connect(read, [ServerName, PoolId, Host, Port, User, Pwd, DB, LogFun, Encoding]=Args, OldState) ->
	Size = mysql_util:get_r_pool_size() - 1,
	if
		Size =< 0 -> OldState;
		true -> do_connect(Size, Args, OldState)
	end;
do_connect(log, [ServerName, PoolId, Host, Port, User, Pwd, DB, LogFun, Encoding]=Args, OldState) ->
	Size = mysql_util:get_l_pool_size() - 1,
	if
		Size =< 0 -> OldState;
		true -> do_connect(Size, Args, OldState)
	end.

