.PHONY: all test benchmark doc repl clean gh-pages

all:
	jbuilder build

test:
	jbuilder runtest

benchmark:
	jbuilder build benchmark/bench.exe
	_build/default/benchmark/bench.exe

doc:
	jbuilder build @doc

repl:
	jbuilder utop src

clean:
	jbuilder clean

gh-pages: doc
	git clone `git config --get remote.origin.url` .gh-pages --reference .
	git -C .gh-pages checkout --orphan gh-pages
	git -C .gh-pages reset
	git -C .gh-pages clean -dxf
	cp  -r _build/default/_doc/* .gh-pages
	git -C .gh-pages add .
	git -C .gh-pages config user.email 'docs@project'
	git -C .gh-pages commit -m "Update Pages"
	git -C .gh-pages push origin gh-pages -f
	rm -rf .gh-pages
