
-module(module_mysql_test).

-compile(export_all).

-record(mysql_test, {key, type, term, string, term2, term3}).

select(FiledList, Conditions) ->
    FormatCond = where_condition_fromat(Conditions),
    Columns = string:join([atom_to_list(Key)||Key<-FiledList], ","),
    SQL = "SELECT " ++ Columns ++ " FROM mysql_test " ++ mysql_helper:pack_where(FormatCond),
    mysql_client:select(mysql_test, SQL).

read(#mysql_test{key = KEY, type = TYPE}) ->
    SQL = "SELECT * FROM mysql_test "++" WHERE `key` = "++mysql_helper:pack_value_by_type({KEY,int})++" AND `type` = "++mysql_helper:pack_value_by_type({TYPE,int})++"",
    mysql_client:read(mysql_test, SQL).

read(KEY, TYPE) ->
    SQL = "SELECT * FROM mysql_test "++" WHERE `key` = "++mysql_helper:pack_value_by_type({KEY,int})++" AND `type` = "++mysql_helper:pack_value_by_type({TYPE,int})++"",
    Res = mysql_client:read(mysql_test, SQL),
    unpack_data(Res, []).

insert({mysql_test, KEY, TYPE, TERM, STRING, TERM2, TERM3}) ->
    mysql_client:insert(mysql_test, "INSERT INTO mysql_test(`key`, `type`, `term`, `string`, `term2`, `term3`) VALUES ("++mysql_helper:pack_value_by_type({KEY,int})++", "++mysql_helper:pack_value_by_type({TYPE,int})++", "++mysql_helper:pack_value_by_type({TERM,term_varchar})++", "++mysql_helper:pack_value_by_type({STRING,varchar})++", "++mysql_helper:pack_value_by_type({TERM2,term_varchar})++", "++mysql_helper:pack_value_by_type({TERM3,timestamp})++");");
insert([#mysql_test{}|_]=INSERTS) ->
	SQL = pack_bash_insert(INSERTS),
	mysql_client:insert(mysql_test, SQL);
insert([]) ->
	nothing.


update_fields(FieldValueList, Conditions) ->
	todo.

delete({mysql_test, KEY, TYPE, TERM, STRING, TERM2, TERM3}) ->
	remove({mysql_test, KEY, TYPE, TERM, STRING, TERM2, TERM3});
delete(Conditions) when is_list(Conditions) ->
	todo.

remove({mysql_test, KEY, TYPE, TERM, STRING, TERM2, TERM3}) ->
	todo.

find(Conditions) ->
    find(Conditions, [], undefined).

%%
%% conditions: [{roleid, '=', 1}, {type, '!=', 3}]
find(Conditions, Limit, OrderBy) ->
	FormateCondition = where_condition_fromat(Conditions),
	SQL = "SELECT * FROM "++atom_to_list(mysql_test)
							++mysql_helper:pack_where(FormateCondition)
							++mysql_helper:pack_orderby(OrderBy)
                            ++mysql_helper:pack_limit(Limit),
	Res = mysql_client:select(mysql_test, SQL),
	unpack_data(Res, []).

all() ->
	SQL = "SELECT * FROM " ++ atom_to_list(mysql_test),
	Res = mysql_client:select(mysql_test, SQL),
	unpack_data(Res, []).

get_key(Record) ->	Record#mysql_test.key.get_type(Record) ->	Record#mysql_test.type.get_term(Record) ->	Record#mysql_test.term.get_string(Record) ->	Record#mysql_test.string.get_term2(Record) ->	Record#mysql_test.term2.get_term3(Record) ->	Record#mysql_test.term3.


unpack_data([RecordFor|Tail], AccInfo) ->
	Record = mysql_helper:unpack_row(mysql_test, RecordFor),
    unpack_data(Tail, [Record#mysql_test{term=mysql_helper:string_to_term(Record#mysql_test.term),						term2=mysql_helper:string_to_term(Record#mysql_test.term2)}|AccInfo]);
unpack_data([], AccInfo) ->
    lists:reverse(AccInfo).


where_condition_fromat(Conditions) ->
    [{Column, Con, {Val, get_column_datatype(Column)}}||{Column, Con, Val} <- Conditions].


get_column_datatype(Column) ->
    proplists:get_value(Column, column_datatype()).

column_datatype() ->
    [{key,int},	 {type,int},	 {term,term_varchar},	 {string,varchar},	 {term2,term_varchar},	 {term3,timestamp}].

get_bash_insert_value_list({mysql_test, KEY, TYPE, TERM, STRING, TERM2, TERM3}) ->
	"("++mysql_helper:pack_value_by_type({KEY,int})++", "++mysql_helper:pack_value_by_type({TYPE,int})++", "++mysql_helper:pack_value_by_type({TERM,term_varchar})++", "++mysql_helper:pack_value_by_type({STRING,varchar})++", "++mysql_helper:pack_value_by_type({TERM2,term_varchar})++", "++mysql_helper:pack_value_by_type({TERM3,timestamp})++")".

pack_bash_insert(Inserts) ->
	Values = string:join([get_bash_insert_value_list(Record)||Record<-Inserts], ", "),
	"INSERT INTO "++erlang:atom_to_list(mysql_test)++"(`key`, `type`, `term`, `string`, `term2`, `term3`) VALUES"++Values++";".

