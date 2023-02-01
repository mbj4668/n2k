FILES = $(wildcard *.csv)

test:
	@for f in $(FILES); do						\
		echo "trying $$f..." | tr -d '\012';			\
		../bin/n2k -q --infmt csv -o $$f.out $$f;		\
		diff $$f.expect $$f.out > $$f.diff ||			\
			{ cat $$f.diff; exit 1; };			\
		rm -f $$f.diff $$f.out;					\
		echo " ok";						\
	done


# needs canbot `analyzer` in PATH
compare:
	@for f in $(FILES); do						\
		echo "=========================================";	\
		echo $$f;						\
		echo "------------";					\
		analyzer -q  < $$f;					\
		echo "----";						\
		../bin/n2k -q --infmt csv -f pretty $$f;		\
	done

clean:
	rm -f *.diff *.out
