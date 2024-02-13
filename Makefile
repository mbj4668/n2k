DESCRIPTION = NMEA 2000 decoder

# all | none | <integer>,<integer>,...
# set this to control code generation of manufacturer proprietary PGNs
MANUFACTURER_CODES = all

# Include used-defined extra rules, see README.md
-include system-config.mk

CUSTOM_PGN_XMLS = $(wildcard $(CUSTOM_DIR)/*-pgns.xml)

CUSTOM_MODULES = $(basename $(notdir $(wildcard $(CUSTOM_DIR)/*.erl)))

PGNS_XML = src/canboat.xml $(CUSTOM_PGN_XMLS)

ifdef CUSTOM_PGN_ERL
PGN_ERL = $(CUSTOM_PGN_ERL)
else
PGN_ERL = none
endif

BEHAVIOR_BEAMS = ebin/n2k_pgn_callback.beam

# Set erl.mk-defined variables

DEPS = eclip

dep_eclip = git https://github.com/mbj4668/eclip.git

ERL_MODULES = n2k_pgn $(CUSTOM_MODULES)
EXCLUDE_ERL_MODULES = gen_n2k_pgn gen_pgns_term n2k_pgn_callback
ERLC_OPTS = -Werror

$(DIALYZER_PLT):
	dialyzer --build_plt --output_plt $(DIALYZER_PLT) \
	  --apps erts kernel stdlib

include erl.mk

erl.mk:
	curl -s -O https://raw.githubusercontent.com/mbj4668/erl.mk/main/$@

src/n2k_pgn.erl: src/pgns.term ebin/gen_n2k_pgn.beam
	erl -noshell -pa ebin -run gen_n2k_pgn gen $< $@

src/pgns.term: ebin/gen_pgns_term.beam $(PGNS_XML)
	erl -noshell -pa ebin -run gen_pgns_term gen $(MANUFACTURER_CODES) \
	$(PGN_ERL) $@ $(PGNS_XML)

ebin/%.beam: $(CUSTOM_DIR)/%.erl $(BEHAVIOR_BEAMS)
	erlc $(ERLC_OPTS) -pa ebin -o ebin $<

clean: n2k-clean

n2k-clean:
	rm -f src/n2k_pgn.erl src/pgns.term

test-build-erl: MANUFACTURER_CODES = all
