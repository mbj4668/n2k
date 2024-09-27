-module(mtab).
-export([format/1, format/2]).

%%% Pretty-prints a list of rows as a table.
%%%
%%% An row can be a list of values, a tuple of values, or
%%% a map of values.
%%%
%%% When the rows are maps, the header is by default the map keys.

-type col() :: #{
                 format_fun => fun() % FIXME type
                , align => left | right | center % left is default
                , width => pos_integer() % default is dynamically calculated
                }.

-spec format(Data :: list(list(unicode:chardata())
                         | #{atom() | unicode:chardata() => unicode:chardata()}
                         | list({atom(), unicode:chardata()})),
             Opts :: #{
                       header => none | first_row
                      , header_fmt => lowercase | uppercase | titlecase
                      , cols => col() | [col()]
                      , style => atom() | map()
                      , fmt_fun => fun((term()) -> unicode:chardata())
                      }) -> iodata().
format(Data) ->
    format(Data, #{}).
format(Data, Opts) ->
    Style = style(maps:get(style, Opts, simple)),
    {Header, Items} = mk_header(Data, Opts),
    Rows = [mk_row(Item) || Item <- Items],
    AllRows = if Header /= undefined -> [Header | Rows];
                 true -> Rows
              end,
    Cols = [C#{width => maps:get(width, C)} ||
               C <- mk_cols(AllRows, maps:get(cols, Opts, undefined))],
    fmt_table(Header, Rows, Cols, Style, Opts).

%%% internal

-record(line, {
               left = []
              , col_sep = []
              , right = []
              , fill = " "
             }).

-record(style, {
                spacer = []
               , first_line :: #line{} | undefined
               , header = #line{} :: #line{}
               , header_sep :: #line{} | undefined
               , row = #line{} :: #line{}
               , row_sep :: #line{} | undefined
               , last_line :: #line{} | undefined
               }).

-record(cell, {
               text :: iodata()
              , width :: pos_integer()  % calculated width of text
              }).

mk_header(Data, #{header := none}) ->
    {undefined, Data};
mk_header([H | _] = Data, #{header := Keys} = Opts)
  when is_map(H), is_list(Keys) ->
    {mk_header_row([to_chardata(Key) || Key <- Keys], Opts),
     maps_to_items(Data, Keys)};
mk_header([H | _] = Data, Opts) when is_map(H) ->
    Keys = maps:keys(H),
    {mk_header_row([to_chardata(Key) || Key <- Keys], Opts),
     maps_to_items(Data, Keys)};
mk_header([[{_, _} | _] = H | _] = Data, Opts) -> % proplist
    {mk_header_row([to_chardata(Key) || {Key, _Val} <- H], Opts),
     proplists_to_items(Data)};
mk_header([H | T], #{header := first_row} = Opts) ->
    {mk_header_row(H, Opts), T};
mk_header(Data, _) ->
    {undefined, Data}.


to_chardata(X) when is_atom(X) -> atom_to_binary(X);
to_chardata(X) -> X.

mk_header_row(Line, Opts) ->
    Row = mk_row(Line),
    [fmt_cells(Cells, maps:get(header_fmt, Opts, default)) || Cells <- Row].

%% FIXME: assumes all proplists have exactly the same members...
proplists_to_items(Data) ->
    [[Val || {_Key, Val} <- Proplist] || Proplist <- Data].

maps_to_items(Data, Keys) ->
    [lists:map(fun(Key) -> maps:get(Key, Map, <<"">>) end, Keys) ||
        Map <- Data].

fmt_cells(Cells, Fmt) ->
    F = case Fmt of
            uppercase -> fun string:uppercase/1;
            lowercase -> fun string:lowercase/1;
            titlecase -> fun titlecase/1;
            default -> fun(X) -> X end
        end,
    [fmt_cell(Cell, F) || Cell <- Cells].

fmt_cell(Cell, F) ->
    Cell#cell{text = F(remove_underscore(Cell#cell.text))}.

titlecase(Str) ->
    string:titlecase(string:lowercase(Str)).

remove_underscore(Str) ->
    string:replace(Str, <<"_">>, <<" ">>, all).

mk_row(Items) when is_tuple(Items) ->
    mk_row(tuple_to_list(Items));
mk_row(Items) when is_list(Items) ->
    Ls = [string:split(fmt(Item), <<"\n">>) || Item <- Items],
    NLines = lists:max([length(L) || L <- Ls]),
    lists:map(
      fun(N) -> [mk_cells(L, N) || L <- Ls] end,
      lists:seq(1, NLines)).

mk_cells(L, N) ->
    case length(L) of
        Len when N =< Len ->
            Text = lists:nth(N, L),
            #cell{text = Text, width = string:length(Text)};
        _ ->
            #cell{text = "", width = 0}
    end.

fmt(Bin) when is_binary(Bin) ->
    Bin;
fmt(List) when is_list(List) ->
    List;
fmt(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom);
fmt(Int) when is_integer(Int) ->
    integer_to_list(Int);
fmt(X) ->
    io_lib:format("~p", [X]).


mk_cols(Rows, ColOpts) ->
    NumCols =
        if is_list(ColOpts) ->
                length(ColOpts);
           true ->
                lists:max([length(hd(Row)) || Row <- Rows])
        end,
    mk_cols(1, NumCols, Rows, ColOpts).

mk_cols(ColN, NumCols, Rows, ColOpts) when ColN =< NumCols ->
    ColOpt0 = get_col_opt(ColN, ColOpts),
    ColOpt1 =
        case maps:is_key(width, ColOpt0) of
            true ->
                ColOpt0;
            false ->
                Width = lists:max([get_col_width(ColN, Row) || Row <- Rows]),
                ColOpt0#{width => Width}
        end,
    [ColOpt1 | mk_cols(ColN+1, NumCols, Rows, ColOpts)];
mk_cols(_, _, _, _) ->
    [].

get_col_opt(_, undefined) ->
    #{align => left};
get_col_opt(_, ColOpt) when is_map(ColOpt) ->
    ColOpt;
get_col_opt(N, ColOpts) when is_list(ColOpts) ->
    lists:nth(N, ColOpts).

get_col_width(ColN, Row) ->
    get_col_width(ColN, Row, 0).
get_col_width(ColN, [Cells | T], MaxWidth) ->
    case length(Cells) of
        Len when ColN =< Len ->
            #cell{width = Width} = lists:nth(ColN, Cells),
            get_col_width(ColN, T, max(Width, MaxWidth));
        _ ->
            get_col_width(ColN, T, MaxWidth)
    end;
get_col_width(_, [], MaxWidth) ->
    MaxWidth.

fmt_table(Header, Rows, Cols, Style, Opts) ->
    #style{spacer = Spacer} = Style,
    SpWidth = string:length(Spacer) * 2,
    [fmt_sep(Style#style.first_line, SpWidth, Cols),
     if Header /= undefined ->
             [fmt_row(Style#style.header, Spacer, Cols, Header, Opts),
              fmt_sep(Style#style.header_sep, SpWidth, Cols)];
        true ->
             []
     end,
     lists:join(fmt_sep(Style#style.row_sep, SpWidth, Cols),
                [fmt_row(Style#style.row, Spacer, Cols, Row, Opts)
                 || Row <- Rows]),
     fmt_sep(Style#style.last_line, SpWidth, Cols)].

fmt_sep(undefined, _, _) ->
    [];
fmt_sep(#line{left = L, col_sep = CS, right = R, fill = F}, SpWidth, Cols) ->
    [L,
     lists:join(CS, [dup(F, SpWidth + maps:get(width, Col)) || Col <- Cols]),
     R,
     $\n].

fmt_row(_, _, _, undefined, _) ->
    [];
fmt_row(#line{left = L, col_sep = CS, right = R}, Spacer, Cols, Row, Opts) ->
    lists:map(
      fun(Cells) ->
              [trim(
                 [L,
                  lists:join(
                    CS, [fmt_cell(Spacer, Cell, Col) ||
                            {Cell, Col}
                                <- lists:zip(pad_cells(Cells, Cols), Cols)]
                   ),
                  R], Opts),
               $\n]
      end, Row).

trim(Str, #{no_trim := true}) ->
    Str;
trim(Str, _) ->
    string:trim(Str, trailing).

pad_cells([CellH | CellT], [_ | ColT]) ->
    [CellH | pad_cells(CellT, ColT)];
pad_cells([], [_ | ColT]) ->
    [#cell{text = "", width = 0} | pad_cells([], ColT)];
pad_cells(_, []) ->
    [].

fmt_cell(Spacer, #cell{text = Text, width = W}, #{align := A, width := ColW}) ->
    [Spacer, align(A, Text, ColW - W), Spacer].

align(left, Text, Pad) ->
    [Text, pad(Pad)];
align(right, Text, Pad) ->
    [pad(Pad), Text];
align(center, Text, Pad) ->
    Left = Pad div 2,
    [pad(Left), Text, pad(Pad - Left)].

dup(Ch, N) ->
    lists:duplicate(N, Ch).

pad(N) ->
    lists:duplicate(N, $\s).

style(plain) -> plain();
style(simple) -> simple();
style(pretty) -> pretty();
style(simple_pretty) -> simple_pretty();
style(presto) -> presto();
style(ascii) -> ascii();
style(simple_grid) -> simple_grid();
style(grid) -> grid();
style(M) when is_map(M) -> mk_style(M).

plain() ->
    #style{}.

simple() ->
    #style{
       header_sep = #line{col_sep = " ", fill = "-"}
      }.

pretty() ->
    #style{
       spacer = " "
      , first_line = #line{left = "+", right = "+", col_sep = "+", fill = "-"}
      , header = #line{left = "|", col_sep = "|", right = "|"}
      , header_sep = #line{left = "+", right = "+", col_sep = "+", fill = "-"}
      , row = #line{left = "|", col_sep = "|", right = "|"}
      , last_line = #line{left = "+", right = "+", col_sep = "+", fill = "-"}
      }.

simple_pretty() ->
    #style{
       spacer = " "
      , header = #line{left = "|", col_sep = "|", right = "|"}
      , header_sep = #line{left = "+", right = "+", col_sep = "+", fill = "-"}
      , row = #line{left = "|", col_sep = "|", right = "|"}
      }.

presto() ->
    #style{
       spacer = " "
      , header = #line{col_sep = "|"}
      , header_sep = #line{col_sep = "+", fill = "-"}
      , row = #line{col_sep = "|"}
      }.

grid() ->
    #style{
       spacer = " "
      , first_line = #line{left = "+", right = "+", col_sep = "+", fill = "-"}
      , header = #line{left = "|", col_sep = "|", right = "|"}
      , header_sep = #line{left = "+", right = "+", col_sep = "+", fill = "="}
      , row = #line{left = "|", col_sep = "|", right = "|"}
      , row_sep = #line{left = "+", right = "+", col_sep = "+", fill = "-"}
      , last_line = #line{left = "+", right = "+", col_sep = "+", fill = "-"}
      }.

simple_grid() ->
    #style{
       spacer = " "
      , header = #line{left = "|", col_sep = "|", right = "|"}
      , header_sep = #line{left = "+", right = "+", col_sep = "+", fill = "="}
      , row = #line{left = "|", col_sep = "|", right = "|"}
      , row_sep = #line{left = "+", right = "+", col_sep = "+", fill = "-"}
      }.

ascii() ->
    #style{
       spacer = " "
      , first_line = #line{left = "+", right = "+", col_sep = "+", fill = "-"}
      , header = #line{left = "|", col_sep = "|", right = "|"}
      , header_sep = #line{left = "+", right = "+", col_sep = "+", fill = "-"}
      , row = #line{left = "|", col_sep = "|", right = "|"}
      , row_sep = #line{left = "+", right = "+", col_sep = "+", fill = "-"}
      , last_line = #line{left = "+", right = "+", col_sep = "+", fill = "-"}
      }.

mk_style(M) ->
    #style{spacer = maps:get(spacer, M, undefined),
           first_line = mk_line(maps:get(first_line, M, undefined)),
           header = mk_line(maps:get(header, M, undefined)),
           header_sep = mk_line(maps:get(header_sep, M, undefined)),
           row = mk_line(maps:get(row, M, undefined)),
           row_sep = mk_line(maps:get(row_sep, M, undefined)),
           last_line = mk_line(maps:get(last_line, M, undefined))
      }.

mk_line(undefined) ->
    undefined;
mk_line(M) ->
    #line{left = maps:get(left, M, undefined),
          right = maps:get(right, M, undefined),
          col_sep = maps:get(col_sep, M, undefined),
          fill = maps:get(fill, M, undefined)}.
