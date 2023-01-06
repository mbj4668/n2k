# NMEA 2000 decoder

An NMEA 2000 decoder in Erlang.  Decodes the following formats:

- Yacht Device's RAW format
- Yacht Device's DAT format
- Yacht Device's CAN format
- CANBOAT's PLAIN format (CSV)

The program `bin/n2k` can be used from the command line to convert or
pretty print files with NMEA 2000 frames or messages in one of the
supported formats.

The functions `n2k_raw:decode_raw/1` and `n2k_csv:decode_csv/1` can be
used to decode captured packets into NMEA 2000 frames.  The frames can
be decoded into messages by calling `n2k:decode_nmea/2`.

The NMEA message decoder is orignally based on code from
https://github.com/tonyrog/nmea_2000.

# Build

NOTE: In order to build this code you need to place a copy of `pgns.xml`
with the pgns you want to be able to decode in `src/`.  E.g., from
canboat.

## Handling of PGNs

At build time, `src/pgns.xml` and any user-defined PGNs XML files are
first compiled into `src/pgns.term` and then
`src/pgns.term` is compiled to `src/n2k_pgn.erl`, which contains code
for decoding NMEA 2000 binary messages into Erlang terms.

Here's an example of the generated code:

```
decode(130306,
       <<Sid:8/little-unsigned,
         WindSpeed:16/little-unsigned,
         WindAngle:16/little-unsigned,
         _6:5, % reserved
         Reference:3/little-unsigned,
         _/bitstring>>) ->

    {windData,
      [{sid,chk_exception2(255,Sid)},
       {windSpeed,chk_exception2(65535,WindSpeed)},
       {windAngle,chk_exception2(65535,WindAngle)},
       {reference,chk_exception1(7,Reference)}]};

%% {int, Resolution, Decimals, Unit}
type_info(windData,windAngle) ->
    {int, 0.0001, 4, rad};
type_info(windData,windSpeed) ->
    {int, 0.01, 2, 'm/s'};
```

## User-defined PGNs

Custom PGNs (or proprietary PGNs that are not part of canboat's
pgns.xml) are defined in the same XML format as canboat uses, with the
addition of an XML element `ErlangModule`, which is optionally
placed in the XML element `PGNInfo`.  The given erlang module must
implement the behavior `n2k_pgn_callback` (see that module for
details).

In order to compile the custom PGN definition files, add a file
`system-config.mk` to the top directory, and define the following
variables:

```
custom_pgns = path/to/my-pgns.xml path/to/other-pgns.xml
custom_pgns_src = path/to/my_pgns.erl path/to/other_pgns.erl
```
