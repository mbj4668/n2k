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

gen([PgnsXmlFile, PgnsTermFile]) ->
    case load_pgns_xml(PgnsXmlFile) of
        {ok, Def} ->
            case save(PgnsTermFile, Def, PgnsXmlFile) of
                ok ->
                    init:stop(0);
                Error ->
                    io:format("** ~p\n", [Error]),
                    init:stop(1)
            end;
        Error ->
            io:format("** ~p\n", [Error]),
            init:stop(1)
    end.

save(File, Def, InFile) ->
    case file:open(File, [write]) of
        {ok, Fd} ->
            try
                ok = write_header(Fd, InFile),
                ok = write_as_term(Fd, Def)
            catch
                error:Reason:Stacktrace ->
                    {error,{Reason, Stacktrace}}
            after
                file:close(Fd)
            end;
        Error ->
            Error
    end.

write_header(Fd, InFile) ->
    io:format(Fd, "%% -*- erlang -*-\n", []),
    io:format(Fd, "%% Generated by ~p from ~s\n", [?MODULE, InFile]),
    io:format(Fd, "\n\n", []).

write_as_term(Fd, [{PGN,Info}|Ps]) ->
    Info1 = patch_info(PGN, Info),
    io:format(Fd, "~p.\n", [{PGN, Info1}]),
    write_as_term(Fd, Ps);
write_as_term(_Fd, []) ->
    ok.

load_pgns_xml(File) ->
    Acc = fun(#xmlText{value = " ", pos = P}, Acc, S) ->
                  {Acc, P, S};  % new return format
             (X, Acc, S) ->
                  {[X|Acc], S}
          end,
    SearchPath = code:priv_dir(nmea_2000),
    case xmerl_scan:file(File,
                         [{space,normalize},
                          {validation,off},
                          {acc_fun, Acc},
                          {fetch_path, [SearchPath]}]) of
        Error = {error,_} ->
            Error;
        {Xml,_Rest} ->
            Node = xmerl_lib:simplify_element(Xml),
            Def  = pgn_definitions(Node),
            %% io:format("Types = ~p\n", [collect_types(Def)]),
            {ok, Def}
    end.

pgn_definitions({'PGNDefinitions',_As,Cs}) ->
    case lists:keyfind('PGNs', 1, Cs) of
        false -> [];
        {'PGNs',_,PGNs} -> pgns(PGNs, [])
    end.

pgns([{'PGNInfo', _As, Cs} | PGNs], Acc) ->
    pgns(PGNs, [pgn_info(Cs,0,[])|Acc]);
pgns([{_, _As, _Cs} | PGNs], Acc) ->
    pgns(PGNs, Acc);
pgns([], Acc) ->
    lists:reverse(Acc).

pgn_info([{'PGN',_As,[Value]}|T],_PGN,Ps) ->
    pgn_info(T, list_to_integer(Value), Ps);
pgn_info([{'Id',_As,[Value]}|T],PGN,Ps) ->
    pgn_info(T, PGN, [{id,Value}|Ps]);
pgn_info([{'Description',_As,Vs}|T],PGN,Ps) ->
    pgn_info(T, PGN, [{description, string(Vs)}|Ps]);
pgn_info([{'Complete',_As,[Value]}|T],PGN,Ps) ->
    pgn_info(T, PGN, [{complete, boolean(Value)}|Ps]);
pgn_info([{'Length',_As,[Value]}|T],PGN,Ps) ->
    pgn_info(T, PGN, [{length, list_to_integer(Value)}|Ps]);
pgn_info([{'RepeatingFields',_As,[Value]}|T],PGN,Ps) ->
    case list_to_integer(Value) of
        0 -> pgn_info(T, PGN, Ps);
        R -> pgn_info(T, PGN, [{repeating_fields,R}|Ps])
    end;
pgn_info([{'RepeatingFieldSet1',_As,[Value]}|T],PGN,Ps) ->
    case list_to_integer(Value) of
        0 -> pgn_info(T, PGN, Ps);
        R -> pgn_info(T, PGN, [{repeating_field_set1,R}|Ps])
    end;
pgn_info([{'RepeatingFieldSet2',_As,[Value]}|T],PGN,Ps) ->
    case list_to_integer(Value) of
        0 -> pgn_info(T, PGN, Ps);
        R -> pgn_info(T, PGN, [{repeating_field_set2,R}|Ps])
    end;
pgn_info([{'Fields',_As,Cs}|T],PGN,Ps) ->
    pgn_info(T, PGN, [{fields,patch_fields(fields(Cs))}|Ps]);
pgn_info([],PGN,Ps) ->
    {PGN, lists:reverse(Ps)}.

patch_fields([]) ->
    [];
patch_fields(Fs) ->
    [H0 | T] = lists:reverse(Fs),
    H1 = proplists:delete(bitstart, H0),
    %% BitStart = proplists:get_value(bitstart, H0),
    %% H2 =
    %%     %% FIXME: see nyi below
    %%     case proplists:get_value(length, H1) of
    %%         Len when Len > 1000, BitStart == 0, nyi == H1 ->
    %%             %% adhoc; treat as unknown length
    %%             lists:keyreplace(length, 1, H1, {length, unknown});
    %%         _ ->
    %%             H1
    %%     end,
    H2 = H1,
    Fs1 = lists:reverse([H2 | T]),
    lists:map(
      fun(F) ->
              case proplists:get_value(id, F) of
                  "manufacturerCode" ->
                      case proplists:get_value(match, F) of
                          undefined ->
                              proplists:delete(type, F) ++
                                  [{type, enum},
                                   {enums, manufacturer_code_enums()}];
                          _ ->
                              F
                      end;
                  _X ->
                      F
              end
      end,
      Fs1).

fields([{'Field',_As,Cs} | T]) ->
    [field(Cs, []) | fields(T)];
fields([]) ->
    [].

field([{'Order',_,[Value]}|T], Fs) ->
    field(T, [{order,list_to_integer(Value)}|Fs]);
field([{'Id',_,Value}|T], Fs) ->
    field(T, [{id,string(Value)}|Fs]);
field([{'Name',_,Value}|T], Fs) ->
    field(T, [{name,string(Value)}|Fs]);
field([{'Description',_,Value}|T], Fs) ->
    field(T, [{description,string(Value)}|Fs]);
field([{'BitLength',_,[Value]}|T], Fs) ->
    field(T, [{length,list_to_integer(Value)}|Fs]);
field([{'Match',_,[Value]}|T], Fs) ->
    field(T, [{match,list_to_integer(Value)}|Fs]);
field([{'Type',_,[Value]}|T], Fs) ->
    field(T, [{type,type(Value)}|Fs]);
field([{'Resolution',_,[Value]}|T], Fs) ->
    case list_to_number(Value) of
        0 -> field(T, Fs);
        1 -> field(T, Fs);
        R -> field(T, [{resolution,R}|Fs])
    end;
field([{'Units',_,Vs}|T], Fs) ->
    field(T, [{units,string(Vs)}|Fs]);
field([{'Signed',_,[Value]}|T], Fs) ->
    case boolean(Value) of
        false -> field(T, Fs);
        true  -> field(T, [{signed,true}|Fs])
    end;
field([{'Offset',_,[Value]}|T], Fs) ->
    field(T, [{offset,list_to_integer(Value)}|Fs]);
field([{'EnumValues',_,Pairs}|T], Fs) ->
    field(T, [{enums, enumpairs(Pairs, 'Value')}|Fs]);
field([{'EnumBitValues',_,Pairs}|T], Fs) ->
    field(T, [{bits, enumpairs(Pairs, 'Bit')}|Fs]);
field([{'BitStart',_,[Value]}|T], Fs) ->  %% not used
    field(T, [{bitstart, list_to_integer(Value)}|Fs]);
field([{'BitOffset',_,[_Value]}|T], Fs) -> %% not used
    field(T, Fs);
field([], Fs) ->
    lists:reverse(Fs).

enumpairs([{'EnumPair',As,_Ps}|T], ValueTagName) ->
    {_,Name} = lists:keyfind('Name',1,As),
    {_,Value} = lists:keyfind(ValueTagName, 1, As),
    try list_to_integer(Value) of
        Int -> [{Name,Int} | enumpairs(T, ValueTagName)]
    catch
        error:_ ->
            [{Name,Value} | enumpairs(T, ValueTagName)]
    end;
enumpairs([], _) ->
    [].

string([]) -> "";
string([Value]) -> Value;
string(Vs) -> lists:flatten(Vs).

boolean("true") -> true;
boolean("false") -> false.

type(undefined) -> undefined;
type("Lookup table") -> enum;
type("Bitfield") -> bits;
type("Binary data") -> binary;
type("Manufacturer code") -> int;
type("Integer") -> int;
type("Temperature") -> int;
type("Temperature (hires)") -> int;
type("Angle") -> int;
type("Date") -> int;
type("Time") -> int;
type("Latitude") -> int;
type("Longitude") -> int;
type("Pressure") -> int;
type("Pressure (hires)") -> int;
type("IEEE Float") -> float;
type("Decimal encoded number") -> bcd;
type("ASCII text") ->
    %% RES_ASCII
    %% fixed length field, if string is shorter it is filled with
    %% 0x00 | 0xff | ' ' | '@'
    string_a;
type("String with start/stop byte") ->
    %% RES_STRING
    %% 0x02 <char>* 0x01 |
    %% 0x03 0x01 0x00 |
    %% <len> 0x01 <char>{<len> - 2}
    string;
type("ASCII or UNICODE string starting with length and control byte") ->
    %% RES_STRINGLAU
    %% <len> <ctrl> <byte>{<len>}
    %% <ctrl> == 0 -> unicode, otherwise ascii
    string_lau;
type("ASCII string starting with length byte") ->
    %% RES_STRINGLZ
    %% <len> <char>* 0x00
    string_lz.

list_to_number(Value) ->
    case string:to_integer(Value) of
        {Int,""} -> Int;
        {Int,E=[$e|_]} ->
            list_to_float(integer_to_list(Int)++".0"++E);
        {Int,E=[$E|_]} ->
            list_to_float(integer_to_list(Int)++".0"++E);
        {_Int,_F=[$.|_]} ->
            list_to_float(Value)
    end.

patch_info(129038, Info) ->
    %% The definition of this message is not correct.  Its length is
    %% 28, but on the network the size is 27.  We solve this by
    %% removing the last field, but that is proably not correct;
    %% that's the sequence id.
    %% We are conservative for now and remove the last 3 fields, which we
    %% don't care about anyway.
    remove_last_fields(Info, 3);
patch_info(129040, Info) ->
    patch_type_of_ship(Info);
patch_info(129794, Info) ->
    patch_type_of_ship(Info);
patch_info(129809, Info) ->
    %% We are conservative for now and remove the last 3 fields, which we
    %% don't care about anyway.
    remove_last_fields(Info, 3);
patch_info(129810, Info) ->
    %% The definition of this message is not correct.  Its length is
    %% 34, but the fields add up to length 35.  The length observed on
    %% the network is 34.
    %% We are conservative for now and remove the last 5 fields, which we
    %% don't care about anyway.
    remove_last_fields(patch_type_of_ship(Info), 5);
patch_info(130842, Info) ->
    patch_type_of_ship(Info);
patch_info(_, Info) ->
    Info.

remove_last_fields(Info, N) ->
    {fields, Fs0} = lists:keyfind(fields, 1, Info),
    Fs1 = lists:sublist(Fs0, length(Fs0) - N),
    lists:keyreplace(fields, 1, Info, {fields, Fs1}).

patch_type_of_ship(Info) ->
    %% typeOfShip definition is incomplete.
    %% See ITU-R M.1371-5
    %% https://api.vtexplorer.com/docs/ref-aistypes.html
    %% https://help.marinetraffic.com/hc/en-us/articles/\
    %% 205579997-What-is-the-significance-of-the-AIS-Shiptype-number-
    {fields, Fs0} = lists:keyfind(fields, 1, Info),
    Fs1 = lists:map(
            fun(Field) ->
                    case lists:member({id,"typeOfShip"}, Field) of
                        true ->
                            patch_type_of_ship_field(Field);
                        false ->
                            Field
                    end
            end, Fs0),
    lists:keyreplace(fields, 1, Info, {fields, Fs1}).

patch_type_of_ship_field(Field) ->
    lists:map(
      fun({enums, _}) ->
              {enums, type_of_ship_enums()};
         (Param) ->
              Param
      end, Field).

type_of_ship_enums() ->
    %% all other values are Reserved
    [{"unavailable",0},
     {"Wing In Ground",20},
     {"Wing In Ground hazard cat X",21},
     {"Wing In Ground hazard cat Y",22},
     {"Wing In Ground hazard cat Z",23},
     {"Wing In Ground hazard cat OS",24},
     {"Wing In Ground (no other information)",29},
     {"Fishing",30},
     {"Towing",31},
     {"Towing exceeds 200m or wider than 25m",32},
     {"Engaged in dredging or underwater operations",33},
     {"Engaged in diving operations",34},
     {"Engaged in military operations",35},
     {"Sailing",36},
     {"Pleasure",37},
     {"High speed craft",40},
     {"High speed craft hazard cat X",41},
     {"High speed craft hazard cat Y",42},
     {"High speed craft hazard cat Z",43},
     {"High speed craft hazard cat OS",44},
     {"High speed craft (no additional information)",49},
     {"Pilot vessel",50},
     {"SAR",51},
     {"Tug",52},
     {"Port tender",53},
     {"Anti-pollution",54},
     {"Law enforcement",55},
     {"Spare",56},
     {"Spare #2",57},
     {"Medical",58},
     {"RR Resolution No.18",59},
     {"Passenger ship",60},
     {"Passenger ship hazard cat X",61},
     {"Passenger ship hazard cat Y",62},
     {"Passenger ship hazard cat Z",63},
     {"Passenger ship hazard cat OS",64},
     {"Passenger ship (no additional information)",69},
     {"Cargo ship",70},
     {"Cargo ship hazard cat X",71},
     {"Cargo ship hazard cat Y",72},
     {"Cargo ship hazard cat Z",73},
     {"Cargo ship hazard cat OS",74},
     {"Cargo ship (no additional information)",79},
     {"Tanker",80},
     {"Tanker hazard cat X",81},
     {"Tanker hazard cat Y",82},
     {"Tanker hazard cat Z",83},
     {"Tanker hazard cat OS",84},
     {"Tanker (no additional information)",89},
     {"Other",90},
     {"Other hazard cat X",91},
     {"Other hazard cat Y",92},
     {"Other hazard cat Z",93},
     {"Other hazard cat OS",94},
     {"Other (no additional information)",99}].

manufacturer_code_enums() ->
    [{"Actia", 199},
     {"Actisense", 273},
     {"Aetna Engineering/Fireboy-Xintex", 215},
     {"Airmar", 135},
     {"Alltek", 459},
     {"Amphenol LTW", 274},
     {"Attwood", 502},
     {"Aquatic", 600},
     {"Au Electronics Group", 735},
     {"Autonnic", 715},
     {"B&G", 381},
     {"Bavaria", 637},
     {"Beede", 185},
     {"BEP", 295},
     {"Beyond Measure", 396},
     {"Blue Water Data", 148},
     {"Evinrude/Bombardier", 163},
     {"CAPI 2", 394},
     {"Carling", 176},
     {"CPAC", 165},
     {"Coelmo", 286},
     {"ComNav", 404},
     {"Cummins", 440},
     {"Dief", 329},
     {"Digital Yacht", 437},
     {"Disenos Y Technologia", 201},
     {"DNA Group", 211},
     {"Egersund Marine", 426},
     {"Electronic Design", 373},
     {"Em-Trak", 427},
     {"EMMI Network", 224},
     {"Empirbus", 304},
     {"eRide", 243},
     {"Faria Instruments", 1863},
     {"Fischer Panda", 356},
     {"Floscan", 192},
     {"Furuno", 1855},
     {"Fusion", 419},
     {"FW Murphy", 78},
     {"Garmin", 229},
     {"Geonav", 385},
     {"Glendinning", 378},
     {"GME / Standard", 475},
     {"Groco", 272},
     {"Hamilton Jet", 283},
     {"Hemisphere GPS", 88},
     {"Honda", 257},
     {"Hummingbird", 467},
     {"ICOM", 315},
     {"JRC", 1853},
     {"Kvasar", 1859},
     {"Kohler", 85},
     {"Korea Maritime University", 345},
     {"LCJ Capteurs", 499},
     {"Litton", 1858},
     {"Livorsi", 400},
     {"Lowrance", 140},
     {"Maretron", 137},
     {"Marinecraft (SK)", 571},
     {"MBW", 307},
     {"Mastervolt", 355},
     {"Mercury", 144},
     {"MMP", 1860},
     {"Mystic Valley Comms", 198},
     {"National Instruments", 529},
     {"Nautibus", 147},
     {"Navico", 275},
     {"Navionics", 1852},
     {"Naviop", 503},
     {"Nobeltec", 193},
     {"Noland", 517},
     {"Northern Lights", 374},
     {"Northstar", 1854},
     {"Novatel", 305},
     {"Ocean Sat", 478},
     {"Ocean Signal", 777},
     {"Offshore Systems", 161},
     {"Orolia (McMurdo)", 573},
     {"Qwerty", 328},
     {"Parker Hannifin", 451},
     {"Raymarine", 1851},
     {"Rolls Royce", 370},
     {"Rose Point", 384},
     {"SailorMade/Tetra", 235},
     {"San Jose", 580},
     {"San Giorgio", 460},
     {"Sanshin (Yamaha)", 1862},
     {"Sea Cross", 471},
     {"Sea Recovery", 285},
     {"Simrad", 1857},
     {"Sitex", 470},
     {"Sleipner", 306},
     {"Standard Horizon", 421},
     {"Teleflex", 1850},
     {"Thrane and Thrane", 351},
     {"Tohatsu", 431},
     {"Transas", 518},
     {"Trimble", 1856},
     {"True Heading", 422},
     {"Twin Disc", 80},
     {"US Coast Guard", 591},
     {"Vector Cantech", 1861},
     {"Veethree", 466},
     {"Vertex", 421},
     {"Vesper", 504},
     {"Victron", 358},
     {"Volvo Penta", 174},
     {"Watcheye", 493},
     {"Westerbeke", 154},
     {"Xantrex", 168},
     {"Yachtcontrol", 583},
     {"Yacht Devices", 717},
     {"Yacht Monitoring Solutions", 233},
     {"Yanmar", 172},
     {"ZF", 228}].
