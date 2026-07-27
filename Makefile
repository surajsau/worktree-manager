.PHONY: macos web

# Rebuild the menu bar app bundle and relaunch it
macos:
	./macos/build-app.sh
	-pkill -x WorktreeManager
	sleep 1
	open macos/WorktreeManager.app

# Restart the zero-dep web server (http://localhost:4180)
web:
	-pkill -f 'node server.js'
	node server.js
