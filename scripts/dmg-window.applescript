-- Styles the mounted DMG window: icon view, branded background, and the
-- Refman.app -> Applications drag layout. Argument: the volume name.
on run argv
	set volName to item 1 of argv
	tell application "Finder"
		tell disk volName
			open
			set theWindow to container window
			set current view of theWindow to icon view
			set toolbar visible of theWindow to false
			set statusbar visible of theWindow to false
			-- 600 x 400 content area (28pt title bar with the toolbar hidden).
			set the bounds of theWindow to {300, 140, 900, 568}
			set opts to the icon view options of theWindow
			set arrangement of opts to not arranged
			set icon size of opts to 128
			set text size of opts to 13
			set background picture of opts to file ".background:background.tiff"
			set position of item "Refman.app" of theWindow to {150, 205}
			set position of item "Applications" of theWindow to {450, 205}
			-- Close/open forces Finder to flush the layout to .DS_Store.
			close
			open
			update without registering applications
			delay 2
		end tell
	end tell
end run
