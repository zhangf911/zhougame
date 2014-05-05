%% Author: Administrator
%% Created: 2014-4-22
%% Description: TODO: Add description to mysql_module_gen
-module(mysql_module_gen).

%%
%% Include files
%%
-include("module_define.hrl").

-define(FilePre, "module_").


%%
%% Exported Functions
%%
-export([]).
-compile(export_all).

%%
%% API Functions
%%
file_test() ->
    {[ModuleInfos], _ProtoInfos} = mysql_config:read_config(),
    Content = formate_values(ModuleInfos),
    {ok, File} = file:open("../log/mysql_test.erl", [write]),
%%     io:format(">>>>>>>>> ~p~n", [{Content}]),
    file:write(File, Content).

formate_values(#module_define{module_name = ModuleName, columns = Cols, primary_key = PriKeys,
                              index = Indexs, engine = Eng}=MoudleRecord) ->
    FileName = ?FilePre++erlang:atom_to_list(ModuleName),
    ModuleNameS = atom_to_list(ModuleName),
    ConvertFun =
        fun(#columns_define{col_name = Name, type = Type}, {AccTypeArgList, AccArgList, AccArgUps, AccArgs}) ->
                NameString = atom_to_list(Name),
                NameToUpper = string:to_upper(atom_to_list(Name)),
                {[{Name, Type}|AccTypeArgList],
                 [NameString++" = "++NameToUpper|AccArgList],
                 [NameToUpper|AccArgUps],
                 [NameString|AccArgs]};
           (_, Values) ->
                Values
        end,
    {TypeArgList, ArgListTemp, ArgUpsTemp, ArgsTemp} =
        lists:foldr(ConvertFun, {[], [], [], []}, Cols),
    
    ArgList = string:join(ArgListTemp, ", "),
    ArgUps  = string:join(ArgUpsTemp, ", "),
    Args    = string:join(ArgsTemp, ", "),
    
    io:format(">>>>>>>>>>>>> ~p~n", [{TypeArgList, ArgList, ArgUps, Args}]),
    
    ValueTest = pack_insert(atom_to_list(ModuleName), Args, TypeArgList),
    
    TestReplace = mysql_op_gen:key_value_replace([{"$FILENAME", FileName},
                                                  {"$RECORDS", Args},
                                                  {"$MODULENAME", ModuleNameS},
                                                  {"$RECORDVALUES", ArgList},
                                                  {"$SQL_INSERT0", ValueTest}
                                                 ], 'module_template'()),
    TestReplace.

formate_key_values(Keys, Records) ->
    string:join([begin
                     case lists:member(Key, Records) of
                         true ->
                             lists:concat([Key, " = ", string:to_upper(atom_to_list(Key))]);
                         false ->
                             throw("Not Found Key")
                     end
                 end||Key<-Keys], ", ").


pack_insert(ModuleName, TableArgsString, TypeArgList) ->
	"INSERT INTO "++ModuleName++"("++TableArgsString++") VALUES "++pack_values_of_insert0(TypeArgList)++";".

pack_values_of_insert0(TypeArgList) ->
	Values = string:join(["\"++mysql_helper:pack_value_by_type("++value_format(Value)++")++\"" ||Value<-TypeArgList], ", "),
	"("++Values++")".

value_format({Name, Type}) ->
	"{"++string:to_upper(atom_to_list(Name))++","++atom_to_list(Type)++"}".


'module_template'() ->
"
-module($FILENAME).

-compile(export_all).

-record($MODULENAME, {$RECORDS}).

select(FiledList, Conditions) ->
    FormatCond = where_condition_fromat(Conditions),
    Columns = string:join([atom_to_list(Key)||Key<-FiledList], \",\"),
    SQL = \"SELECT \" ++ Columns ++ \" FROM $MODULENAME \" ++ mysql_helper:pack_where(FormatCond),
    mysql_client:select($MODULENAME, SQL).

read(#$MODULENAME{$KEYVALUES}) ->
    SQL = \"SELECT * FROM $MODULENAME WHERE $PACKKEYS,
    mysql_client:read($MODULENAME, SQL);
read($KEYS) ->
    SQL = \"SELECT * FROM $MODULENAME WHERE $PACKKEYS,
    Res = mysql_client:read($MODULENAME, SQL),
    unpack_data(Res, []).

insert(#$MODULENAME{$RECORDVALUES}) ->
    mysql_client:insert(role_han_grave_db, \"$SQL_INSERT0\");


unpack_data([[#VALUESRECORD]|Tail], AccInfo) ->
    unpack_data(Tail, [$MODULENAME{$VALUESPACKS}|AccInfo]);
unpack_data([], AccInfo) ->
    lists:reverse(AccInfo).


where_condition_fromat(Conditions) ->
    [{Column, Con, {Val, get_column_datatype(Column)}}||{Column, Con, Val} <- Conditions].


get_column_datatype(Column) ->
    proplists:get_value(Column, column_datatype()).

column_datatype() ->
    [$RECORDDEFINES].
".



%%
%% Local Functions
%%



