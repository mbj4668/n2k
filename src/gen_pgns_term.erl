%%% Original code by Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2015, Tony Rogvall
%%% Modified by Martin Björklund
%%%   - new interface
%%%
%%% Used at compile time to generate an Erlang term version of
%%% the XML definition of PGNS.
-module(gen_pgns_term).
-export([gen/1]).

-include_lib("xmerl/include/xmerl.hrl").

gen([ManufacturersStr, PgnErlStr, PgnsTermFile | PgnsXmlFiles]) ->
    try
        Manufacturers = parse_manufacturers(ManufacturersStr),
        PgnErl = parse_pgn_erl(PgnErlStr),
        case load_pgns_xml(PgnsXmlFiles) of
            {ok, Def0} ->
                Def1 = process_def(Def0, Manufacturers, PgnErl),
                case save(PgnsTermFile, Def1, PgnsXmlFiles) of
                    ok ->
                        init:stop(0);
                    Error ->
                        io:format(standard_error, "** ~p\n", [Error]),
                        init:stop(1)
                end;
            Error ->
                io:format(standard_error, "** ~p\n", [Error]),
                init:stop(1)
        end
    catch
        exit:Error1 ->
            io:format(standard_error, "** ~p\n", [Error1]),
            init:stop(1)
    end.

parse_manufacturers("all") ->
    all;
parse_manufacturers("none") ->
    [];
parse_manufacturers(Str) ->
    [list_to_integer(B) || B <- string:split(Str, ",", all)].

parse_pgn_erl("none") ->
    [];
parse_pgn_erl(Str) ->
    PairStrL = string:split(Str, ",", all),
    lists:map(
        fun(PairStr) ->
            [PGN, Mod] = string:split(PairStr, ":", all),
            {PGN, Mod}
        end,
        PairStrL
    ).

save(File, Def, InFiles) ->
    case file:open(File, [write, {encoding, utf8}]) of
        {ok, Fd} ->
            try
                ok = write_header(Fd, InFiles),
                ok = io:format(Fd, "~p.\n", [Def])
            catch
                error:Reason:Stacktrace ->
                    {error, {Reason, Stacktrace}}
            after
                file:close(Fd)
            end;
        Error ->
            Error
    end.

write_header(Fd, InFiles) ->
    io:format(Fd, "%% -*- erlang -*-\n", []),
    io:format(
        Fd,
        "%% Generated by ~p from ~s\n",
        [?MODULE, lists:join(", ", InFiles)]
    ),
    io:format(Fd, "\n\n", []).

load_pgns_xml(Files) ->
    AccF = fun
        (#xmlText{value = " ", pos = P}, Acc, S) ->
            % new return format
            {Acc, P, S};
        (X, Acc, S) ->
            {[X | Acc], S}
    end,
    try
        Defs =
            lists:foldl(
                fun(File, Acc) ->
                    case
                        xmerl_scan:file(
                            File,
                            [
                                {space, normalize},
                                {validation, off},
                                {acc_fun, AccF}
                            ]
                        )
                    of
                        Error = {error, _} ->
                            throw(Error);
                        {Xml, _Rest} ->
                            Node = xmerl_lib:simplify_element(Xml),
                            pgn_definitions(File, Node, Acc)
                    end
                end,
                {[], [], [], []},
                Files
            ),
        {ok, Defs}
    catch
        throw:Error ->
            Error
    end.

pgn_definitions(
    File,
    {'PGNDefinitions', _As, Cs},
    {PGNsAcc, Enums1Acc, Enums2Acc, Bits1Acc}
) ->
    case lists:keyfind('SchemaVersion', 1, Cs) of
        {'SchemaVersion', _, ["2.0.0"]} ->
            ok;
        {'SchemaVersion', _, [UnknownVersion]} ->
            throw(File ++ ": unknown SchemaVersion: " ++ UnknownVersion);
        false ->
            throw(File ++ ": expected SchemaVersion element in PGNDefinitions")
    end,
    {
        case lists:keyfind('PGNs', 1, Cs) of
            false -> PGNsAcc;
            {'PGNs', _, PGNs} -> pgns(PGNs, PGNsAcc)
        end,
        case lists:keyfind('LookupEnumerations', 1, Cs) of
            false -> Enums1Acc;
            {'LookupEnumerations', _, Enums1} -> enums1(Enums1, Enums1Acc)
        end,
        case lists:keyfind('LookupIndirectEnumerations', 1, Cs) of
            false -> Enums2Acc;
            {'LookupIndirectEnumerations', _, Enums2} -> enums2(Enums2, Enums2Acc)
        end,
        case lists:keyfind('LookupBitEnumerations', 1, Cs) of
            false -> Bits1Acc;
            {'LookupBitEnumerations', _, Bits1} -> bits1(Bits1, Bits1Acc)
        end
    }.

pgns([{'PGNInfo', _As, Cs} | PGNs], Acc) ->
    pgns(PGNs, [pgn_info(Cs, 0, []) | Acc]);
pgns([{_, _As, _Cs} | PGNs], Acc) ->
    pgns(PGNs, Acc);
pgns([], Acc) ->
    lists:reverse(Acc).

pgn_info([{'PGN', _As, [Value]} | T], _PGN, Ps) ->
    pgn_info(T, list_to_integer(Value), Ps);
pgn_info([{'Id', _As, [Value]} | T], PGN, Ps) ->
    pgn_info(T, PGN, [{id, Value} | Ps]);
pgn_info([{'Description', _As, Vs} | T], PGN, Ps) ->
    pgn_info(T, PGN, [{description, string(Vs)} | Ps]);
pgn_info([{'ErlangModule', _As, Vs} | T], PGN, Ps) ->
    pgn_info(T, PGN, [{erlang_module, string(Vs)} | Ps]);
pgn_info([{'Type', _As, [Value]} | T], PGN, Ps) ->
    Type =
        case Value of
            "Single" -> single;
            "Fast" -> fast;
            "ISO" -> iso;
            "Mixed" -> mixed
        end,
    pgn_info(T, PGN, [{type, Type} | Ps]);
pgn_info([{'Fallback', _As, [Value]} | T], PGN, Ps) ->
    pgn_info(T, PGN, [{fallback, list_to_atom(Value)} | Ps]);
pgn_info([{'RepeatingFieldSet1', _As, [Value]} | T], PGN, Ps) ->
    pgn_info(T, PGN, [{repeating_field_set1, list_to_integer(Value)} | Ps]);
pgn_info([{'RepeatingFieldSet1Size', _As, [Value]} | T], PGN, Ps) ->
    pgn_info(T, PGN, [{repeating_field_set1_size, list_to_integer(Value)} | Ps]);
pgn_info([{'RepeatingFieldSet1StartField', _As, [Value]} | T], PGN, Ps) ->
    pgn_info(T, PGN, [
        {repeating_field_set1_start_field, list_to_integer(Value)}
        | Ps
    ]);
pgn_info([{'RepeatingFieldSet1CountField', _As, [Value]} | T], PGN, Ps) ->
    pgn_info(T, PGN, [
        {repeating_field_set1_count_field, list_to_integer(Value)}
        | Ps
    ]);
pgn_info([{'RepeatingFieldSet2', _As, [Value]} | T], PGN, Ps) ->
    pgn_info(T, PGN, [{repeating_field_set2, list_to_integer(Value)} | Ps]);
pgn_info([{'RepeatingFieldSet2Size', _As, [Value]} | T], PGN, Ps) ->
    pgn_info(T, PGN, [{repeating_field_set2_size, list_to_integer(Value)} | Ps]);
pgn_info([{'RepeatingFieldSet2StartField', _As, [Value]} | T], PGN, Ps) ->
    pgn_info(T, PGN, [
        {repeating_field_set2_start_field, list_to_integer(Value)}
        | Ps
    ]);
pgn_info([{'RepeatingFieldSet2CountField', _As, [Value]} | T], PGN, Ps) ->
    pgn_info(T, PGN, [
        {repeating_field_set2_count_field, list_to_integer(Value)}
        | Ps
    ]);
pgn_info([{'Fields', _As, Cs} | T], PGN, Ps) ->
    pgn_info(T, PGN, [{fields, fields(Cs)} | Ps]);
pgn_info([{'Complete', _As, _Cs} | T], PGN, Ps) ->
    pgn_info(T, PGN, Ps);
pgn_info([{'Missing', _As, _Cs} | T], PGN, Ps) ->
    pgn_info(T, PGN, Ps);
pgn_info([{'Explanation', _As, _Cs} | T], PGN, Ps) ->
    pgn_info(T, PGN, Ps);
pgn_info([{'URL', _As, _Cs} | T], PGN, Ps) ->
    pgn_info(T, PGN, Ps);
pgn_info([{'FieldCount', _As, _Cs} | T], PGN, Ps) ->
    pgn_info(T, PGN, Ps);
pgn_info([{'Length', _As, _Cs} | T], PGN, Ps) ->
    pgn_info(T, PGN, Ps);
pgn_info([{'MinLength', _As, _Cs} | T], PGN, Ps) ->
    pgn_info(T, PGN, Ps);
pgn_info([{'TransmissionIrregular', _As, _Cs} | T], PGN, Ps) ->
    pgn_info(T, PGN, Ps);
pgn_info([{'TransmissionInterval', _As, _Cs} | T], PGN, Ps) ->
    pgn_info(T, PGN, Ps);
pgn_info([], PGN, Ps) ->
    {PGN, lists:reverse(Ps)}.

fields(Es) ->
    [field(Cs, [], Es) || {'Field', _As, Cs} <- Es].

field([{'Order', _, [Value]} | T], Fs, Es) ->
    field(T, [{order, list_to_integer(Value)} | Fs], Es);
field([{'Id', _, Value} | T], Fs, Es) ->
    field(T, [{id, string(Value)} | Fs], Es);
field([{'Name', _, Value} | T], Fs, Es) ->
    field(T, [{name, string(Value)} | Fs], Es);
field([{'Description', _, Value} | T], Fs, Es) ->
    field(T, [{description, string(Value)} | Fs], Es);
field([{'BitLength', _, [Value]} | T], Fs, Es) ->
    field(T, [{length, list_to_integer(Value)} | Fs], Es);
field([{'BitLengthVariable', _, [Value]} | T], Fs, Es) ->
    field(T, [{var_length, boolean(Value)} | Fs], Es);
field([{'BitLengthField', _, [Value]} | T], Fs, Es) ->
    field(T, [{bit_length_field, list_to_integer(Value)} | Fs], Es);
field([{'Match', _, [Value]} | T], Fs, Es) ->
    field(T, [{match, list_to_integer(Value)} | Fs], Es);
field([{'FieldType', _, [Value]} | T], Fs, Es) ->
    field(T, [{type, field_type(Value)} | Fs], Es);
field([{'RangeMax', _, [Value]} | T], Fs, Es) ->
    try list_to_integer(Value) of
        RangeMax ->
            field(T, [{range_max, RangeMax} | Fs], Es)
    catch
        _:_ ->
            field(T, Fs, Es)
    end;
field([{'LookupBitEnumeration', _, [Value]} | T], Fs, Es) ->
    field(T, [{bit, Value} | Fs], Es);
field([{'LookupEnumeration', _, [Value]} | T], Fs, Es) ->
    field(T, [{enum, Value} | Fs], Es);
field([{'LookupIndirectEnumeration', _, [Value]} | T], Fs, Es) ->
    field(T, [{enum2, Value} | Fs], Es);
field([{'LookupIndirectEnumerationFieldOrder', _, [Value]} | T], Fs, Es) ->
    Id = order_to_id(Es, Value),
    field(T, [{enum2_field, Id} | Fs], Es);
field([{'Resolution', _, [Value]} | T], Fs, Es) ->
    case list_to_number(Value) of
        0 -> field(T, Fs, Es);
        1 -> field(T, Fs, Es);
        R -> field(T, [{resolution, R} | Fs], Es)
    end;
field([{'Unit', _, Vs} | T], Fs, Es) ->
    field(T, [{unit, string(Vs)} | Fs], Es);
field([{'Signed', _, [Value]} | T], Fs, Es) ->
    case boolean(Value) of
        false -> field(T, Fs, Es);
        true -> field(T, [{signed, true} | Fs], Es)
    end;
field([{'Endian', _, [Value]} | T], Fs, Es) ->
    case Value of
        "little" -> field(T, [{endian, little} | Fs], Es);
        "big" -> field(T, [{endian, big} | Fs], Es)
    end;
field([{'EnumValues', _, Pairs} | T], Fs, Es) ->
    field(T, [{enums, enumpairs(Pairs, 'Value')} | Fs], Es);
field([{'EnumBitValues', _, Pairs} | T], Fs, Es) ->
    field(T, [{bits, enumpairs(Pairs, 'Bit')} | Fs], Es);
%% not used
field([{'Offset', _, [_Value]} | T], Fs, Es) ->
    field(T, Fs, Es);
%% not used
field([{'BitStart', _, [_Value]} | T], Fs, Es) ->
    field(T, Fs, Es);
%% not used
field([{'BitOffset', _, [_Value]} | T], Fs, Es) ->
    field(T, Fs, Es);
%% not used
field([{'RangeMin', _, [_Value]} | T], Fs, Es) ->
    field(T, Fs, Es);
%% not used
field([{'Condition', _, [_Value]} | T], Fs, Es) ->
    field(T, Fs, Es);
%% not used
field([{'PhysicalQuantity', _, [_Value]} | T], Fs, Es) ->
    field(T, Fs, Es);
field([], Fs, _Es) ->
    lists:reverse(Fs).

order_to_id([{'Field', _, Cs} | T], Order) ->
    case lists:keyfind('Order', 1, Cs) of
        {'Order', _, [Order]} ->
            {'Id', _, [Value]} = lists:keyfind('Id', 1, Cs),
            Value;
        _ ->
            order_to_id(T, Order)
    end.

enums1([{'LookupEnumeration', As, Cs} | T], Acc) ->
    Name = proplists:get_value('Name', As),
    NewEnumPairs = enumpairs(Cs),
    %% we allow merge of enums; specific use case is the addition of
    %% manufacturer codes that are not officially registered
    case lists:keytake(Name, 1, Acc) of
        {value, {Name, OldEnumPairs}, Acc1} ->
            enums1(T, [{Name, NewEnumPairs ++ OldEnumPairs} | Acc1]);
        _ ->
            enums1(T, [{Name, NewEnumPairs} | Acc])
    end;
enums1([{_, _As, _Cs} | T], Acc) ->
    enums1(T, Acc);
enums1([], Acc) ->
    lists:reverse(Acc).

enumpairs([{'EnumPair', As, _Cs} | T]) ->
    Name = proplists:get_value('Name', As),
    Value = proplists:get_value('Value', As),
    [{list_to_binary(Name), list_to_integer(Value)} | enumpairs(T)];
enumpairs([_ | T]) ->
    enumpairs(T);
enumpairs([]) ->
    [].

enums2([{'LookupIndirectEnumeration', As, Cs} | T], Acc) ->
    Name = proplists:get_value('Name', As),
    NewEnumTriplets = enumtriplets(Cs),
    %% we allow merge of enums
    case lists:keytake(Name, 1, Acc) of
        {value, {Name, OldEnumTriplets}, Acc1} ->
            enums2(T, [{Name, NewEnumTriplets ++ OldEnumTriplets} | Acc1]);
        _ ->
            enums2(T, [{Name, NewEnumTriplets} | Acc])
    end;
enums2([{_, _As, _Cs} | T], Acc) ->
    enums2(T, Acc);
enums2([], Acc) ->
    lists:reverse(Acc).

enumtriplets([{'EnumTriplet', As, _Cs} | T]) ->
    Name = proplists:get_value('Name', As),
    Value1 = proplists:get_value('Value1', As),
    Value2 = proplists:get_value('Value2', As),
    [
        {Name, {list_to_integer(Value1), list_to_integer(Value2)}}
        | enumtriplets(T)
    ];
enumtriplets([_ | T]) ->
    enumtriplets(T);
enumtriplets([]) ->
    [].

bits1([{'LookupBitEnumeration', As, Cs} | T], Acc) ->
    Name = proplists:get_value('Name', As),
    bits1(T, [{Name, bitpairs(Cs)} | Acc]);
bits1([{_, _As, _Cs} | T], Acc) ->
    bits1(T, Acc);
bits1([], Acc) ->
    lists:reverse(Acc).

bitpairs([{'BitPair', As, _Cs} | T]) ->
    Name = proplists:get_value('Name', As),
    Bit = proplists:get_value('Bit', As),
    [{Name, list_to_integer(Bit)} | bitpairs(T)];
bitpairs([_ | T]) ->
    bitpairs(T);
bitpairs([]) ->
    [].

enumpairs([{'EnumPair', As, _Ps} | T], ValueTagName) ->
    {_, Name} = lists:keyfind('Name', 1, As),
    {_, Value} = lists:keyfind(ValueTagName, 1, As),
    try list_to_integer(Value) of
        Int -> [{Name, Int} | enumpairs(T, ValueTagName)]
    catch
        error:_ ->
            [{Name, Value} | enumpairs(T, ValueTagName)]
    end;
enumpairs([], _) ->
    [].

string([]) -> "";
string([Value]) -> Value;
string(Vs) -> lists:flatten(Vs).

boolean("true") -> true;
boolean("false") -> false.

field_type("BINARY") ->
    binary;
field_type("BITLOOKUP") ->
    bits;
field_type("FLOAT") ->
    float;
field_type("NUMBER") ->
    int;
field_type("DECIMAL") ->
    bcd;
field_type("LOOKUP") ->
    enum;
field_type("INDIRECT_LOOKUP") ->
    enum2;
field_type("TIME") ->
    int;
field_type("DATE") ->
    int;
field_type("MMSI") ->
    int;
field_type("RESERVED") ->
    reserved;
field_type("SPARE") ->
    reserved;
field_type("VARIABLE") ->
    variable;
field_type("STRING_FIX") ->
    %% n2k: DF63
    %% fixed length field, if string is shorter it is filled with
    %% 0x00 | 0xff | ' ' | '@'
    string_fixed;
field_type("STRING_LAU") ->
    %% n2k: DF50
    %% <len> <ctrl> <byte>{<len>}
    %% <ctrl> == 0 -> unicode utf-16
    %% <ctrl> == 1 -> ascii
    string_variable_short;
%type("DF51") ->  % two-byte length for longer strings
%    %% n2k: DF51
%    %% <len1> <len2> <ctrl> <byte>{<len>}
%    %% <ctrl> == 0 -> unicode utf-16
%    %% <ctrl> == 1 -> ascii
%    string_variable_medium;
field_type("STRING_LZ") ->
    %% NOTE: this is a non-standard string type; used in old fusion PGNs.
    %% <len> <char>*
    string_lz.

list_to_number(Value) ->
    case string:to_integer(Value) of
        {Int, ""} -> Int;
        {Int, E = [$e | _]} -> list_to_float(integer_to_list(Int) ++ ".0" ++ E);
        {Int, E = [$E | _]} -> list_to_float(integer_to_list(Int) ++ ".0" ++ E);
        {_Int, _F = [$. | _]} -> list_to_float(Value)
    end.

process_def({PGNs, Enums1, Enums2, Bits1}, Manufacturers, PgnErl) ->
    NewPGNs0 = patch_pgns(lists:keysort(1, PGNs), PgnErl),
    NewPGNs1 = filter_pgns(NewPGNs0, Manufacturers),
    NewPGNs2 = expand_pgns(NewPGNs1),
    {NewPGNs2, Enums1, Enums2, Bits1}.

%% o  Remove all "fallback" definitions.  These are not proper
%%    definitons anyway
%% o  Remove all PGNs w/o fields.
%% o  Remove unwanted manufacturer proprietary PGNs
filter_pgns(PGNs, Manufacturers) ->
    [
        {PGN, Info}
     || {PGN, Info} <- PGNs,
        (not lists:member({fallback, true}, Info)) andalso
            lists:keymember(fields, 1, Info) andalso
            (Manufacturers == all orelse
                pick_pgn_p(Info, Manufacturers))
    ].

pick_pgn_p(Info, Manufacturers) ->
    case lists:keyfind(manufacturerCode, 1, Info) of
        {manufacturerCode, Code} ->
            lists:member(Code, Manufacturers);
        _ ->
            true
    end.

patch_pgns(PGNs, PgnErl) ->
    [
        {PGN,
            patch_manufacturer(
                patch_erlang_module(
                    patch_ais_sequence_id(PGN, Info),
                    PgnErl
                )
            )}
     || {PGN, Info} <- PGNs
    ].

%% For each manufacturer proprietary PGN, add the manufacturerId to Info
patch_manufacturer(Info) ->
    case lists:keyfind(fields, 1, Info) of
        {fields, Fs} ->
            case find_manufacturer_code(Fs) of
                false ->
                    Info;
                {true, Code} ->
                    Info ++ [{manufacturerCode, Code}]
            end;
        _ ->
            Info
    end.

find_manufacturer_code([F | T]) ->
    case lists:member({id, "manufacturerCode"}, F) of
        true ->
            case lists:keyfind(match, 1, F) of
                {match, Code} ->
                    {true, Code};
                false ->
                    find_manufacturer_code(T)
            end;
        false ->
            false
    end;
find_manufacturer_code([]) ->
    false.

patch_erlang_module(Info, PgnErl) ->
    Id = proplists:get_value(id, Info),
    case lists:keyfind(Id, 1, PgnErl) of
        {_, ErlMod} ->
            [{erlang_module, ErlMod} | Info];
        _ ->
            Info
    end.

%% According to "New NMEA 2000 Edition 3.00 Release",
%% "20130121 nmea 2000 edition 3 00 release document.pdf",
%% all AIS-related PGNs have new Sequence ID field added.
%% However, it is only added to three of these PGNs in canboat.
%% Since it seems that many devices don't send it, we handle this
%% by generating variations (see add_variations() below).
patch_ais_sequence_id(PGN, Info) ->
    case is_ais_with_sequence_id(PGN) of
        true ->
            patch_last_sequence_id(Info);
        false ->
            Info
    end.

is_ais_with_sequence_id(PGN) ->
    case PGN of
        129038 -> true;
        %% In canboat, only three of all AIS PGNs have sequenceId
        %        129039 -> true;
        %        129040 -> true;
        %        129793 -> true;
        %        129794 -> true;
        %        129796 -> true;
        %        129797 -> true;
        %        129798 -> true;
        %        129800 -> true;
        %        129801 -> true;
        %        129802 -> true;
        %        129803 -> true;
        %        129804 -> true;
        %        129805 -> true;
        %        129806 -> true;
        %        129807 -> true;
        129809 -> true;
        129810 -> true;
        _ -> false
    end.

patch_last_sequence_id(Info) ->
    {fields, Fs0} = lists:keyfind(fields, 1, Info),
    [Last | T] = lists:reverse(Fs0),
    %% assertion
    "sequenceId" = proplists:get_value(id, Last),
    Last1 = Last ++ [{new_in, "2.000"}],
    Fs1 = lists:reverse([Last1 | T]),
    lists:keyreplace(fields, 1, Info, {fields, Fs1}).

expand_pgns(PGNs) ->
    NewPGNsRev =
        lists:foldl(
            fun({PGN, Info} = H, Acc) ->
                {fields, Fs} = lists:keyfind(fields, 1, Info),
                F = lists:last(Fs),
                case proplists:get_value(new_in, F) of
                    undefined ->
                        [H | Acc];
                    NewIn ->
                        add_variations(
                            lists:reverse(Fs),
                            NewIn,
                            PGN,
                            Info,
                            [H | Acc]
                        )
                end
            end,
            [],
            PGNs
        ),
    lists:reverse(NewPGNsRev).

%% Generate pgn definitions where all fields with the same NewIn are
%% removed.
%% For example, if we have A,B,C[new_in: 2],D[new_in:2],E[new_in:3]
%% we generate 3 variations:
%%  A,B,C,D,E
%%  A,B,C,D,
%%  A,B
add_variations([F | T], NewIn, PGN, Info, Acc) ->
    case proplists:get_value(new_in, F) of
        NewIn ->
            add_variations(T, NewIn, PGN, Info, Acc);
        undefined ->
            Fs1 = lists:reverse([F | T]),
            [{PGN, lists:keyreplace(fields, 1, Info, {fields, Fs1})} | Acc];
        NewIn1 ->
            Fs1 = lists:reverse([F | T]),
            Acc1 =
                [
                    {PGN, lists:keyreplace(fields, 1, Info, {fields, Fs1})}
                    | Acc
                ],
            add_variations(T, NewIn1, PGN, Info, Acc1)
    end.
