.PHONY: app run install clean

app:
	./scripts/bundle.sh

run: app
	open "build/Claude Switcher.app"

install: app
	rm -rf "/Applications/Claude Switcher.app"
	cp -R "build/Claude Switcher.app" /Applications/
	open "/Applications/Claude Switcher.app"

clean:
	rm -rf .build build
