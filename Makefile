.PHONY: macos test render

# Rebuild the menu bar app bundle and relaunch it
macos:
	./macos/build-app.sh
	-pkill -x WorktreeManager
	sleep 1
	open macos/WorktreeManager.app

# Run the test suite (fake data, no repo/gh/network needed).
# `make test FILTER=PanelRenderTests` runs one suite — the filter matches
# type/function names, not the @Test display names.
test:
	cd macos && swift test $(if $(FILTER),--filter $(FILTER),)

# Render the panel from fake data, both appearances, and open them
render:
	cd macos && swift build -c release
	./macos/.build/release/WorktreeManager --render /tmp/panel-light.png --demo
	./macos/.build/release/WorktreeManager --render /tmp/panel-dark.png --demo --dark
	open /tmp/panel-light.png /tmp/panel-dark.png
