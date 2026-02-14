-- OmniFocus to Apple Reminders Sync
-- Exports the full project/task hierarchy, tags, and due dates from OmniFocus
-- and recreates them in Apple Reminders.
--
-- How it works:
--   - Each OmniFocus folder becomes a Reminders list.
--   - Each OmniFocus project becomes a Reminders list (nested under its folder name as a prefix).
--   - Tasks and subtasks are recreated with their hierarchy preserved.
--   - Tags are copied into the Reminders "notes" field (Apple Reminders does not support arbitrary tags natively).
--   - Due dates are preserved.
--   - Completed tasks are marked complete in Reminders.
--
-- Usage: Open this file in Script Editor on macOS and click Run.

-- Configuration
property addCompletedTasks : false -- set to true to also sync completed tasks
property tagSeparator : ", " -- separator used when listing multiple tags
property dryRun : false -- set to true to log actions without writing to Reminders

------------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------------

-- Get or create a Reminders list by name
on getOrCreateList(listName)
	tell application "Reminders"
		if (count of (lists whose name is listName)) > 0 then
			return first list whose name is listName
		else
			set newList to make new list with properties {name:listName}
			return newList
		end if
	end tell
end getOrCreateList

-- Build a tag string from an OmniFocus task's tags
on getTagNames(aTask)
	set tagNames to {}
	tell application "OmniFocus"
		repeat with aTag in (tags of aTask)
			set end of tagNames to (name of aTag as text)
		end repeat
	end tell
	return my joinList(tagNames, tagSeparator)
end getTagNames

-- Join a list of strings with a delimiter
on joinList(theList, delim)
	if (count of theList) = 0 then return ""
	set oldDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to delim
	set joined to theList as text
	set AppleScript's text item delimiters to oldDelims
	return joined
end joinList

-- Build the notes field: includes tags and the OmniFocus note if present
on buildNotes(aTask, tagString)
	set parts to {}
	if tagString is not "" then
		set end of parts to "Tags: " & tagString
	end if
	tell application "OmniFocus"
		set taskNote to note of aTask
		if taskNote is not "" and taskNote is not missing value then
			set end of parts to taskNote
		end if
	end tell
	return my joinList(parts, linefeed & linefeed)
end buildNotes

------------------------------------------------------------------------
-- CORE: Create a reminder from an OmniFocus task
------------------------------------------------------------------------

on createReminder(targetList, aTask, parentReminder)
	tell application "OmniFocus"
		set taskName to name of aTask
		set taskDueDate to due date of aTask
		set isCompleted to completed of aTask
		set taskFlagged to flagged of aTask
	end tell

	-- Skip completed tasks if configured
	if not addCompletedTasks and isCompleted then return

	-- Gather tags
	set tagString to my getTagNames(aTask)

	-- Build notes
	set notesText to my buildNotes(aTask, tagString)

	-- Build reminder properties
	set reminderProps to {name:taskName, body:notesText}

	if taskDueDate is not missing value then
		set reminderProps to reminderProps & {due date:taskDueDate, remind me date:taskDueDate}
	end if

	if dryRun then
		log "  [DRY RUN] Would create reminder: " & taskName
		return
	end if

	-- Create the reminder in Apple Reminders
	tell application "Reminders"
		if parentReminder is missing value then
			-- Top-level reminder in the list
			set newReminder to make new reminder at end of reminders of targetList with properties reminderProps
		else
			-- Sub-reminder (child) of an existing reminder
			set newReminder to make new reminder at end of reminders of targetList with properties reminderProps
			-- Apple Reminders supports subtasks via the "parent" property (macOS 13+)
			try
				set parent of newReminder to parentReminder
			on error
				-- Fallback: prefix the name to indicate hierarchy if subtask parenting is unsupported
				set name of newReminder to ("  - " & taskName)
			end try
		end if

		-- Mark completed if needed
		if isCompleted and addCompletedTasks then
			set completed of newReminder to true
		end if

		-- Set priority if flagged
		if taskFlagged then
			set priority of newReminder to 1
		end if
	end tell

	-- Recurse into subtasks
	tell application "OmniFocus"
		set subtasks to tasks of aTask
	end tell

	repeat with childTask in subtasks
		tell application "Reminders"
			my createReminder(targetList, childTask, newReminder)
		end tell
	end repeat
end createReminder

------------------------------------------------------------------------
-- CORE: Process a single OmniFocus project
------------------------------------------------------------------------

on processProject(proj, listPrefix)
	tell application "OmniFocus"
		set projName to name of proj
		set projStatus to status of proj
	end tell

	-- Skip dropped projects
	if projStatus is "dropped status" then return

	-- Determine list name
	if listPrefix is "" then
		set listName to projName
	else
		set listName to listPrefix & " : " & projName
	end if

	log "Processing project: " & listName

	-- Get or create the corresponding Reminders list
	set targetList to my getOrCreateList(listName)

	-- Add project-level note/tags as a description reminder if useful
	tell application "OmniFocus"
		set projNote to note of proj
		set projDueDate to due date of proj
		set topTasks to root task of proj
	end tell

	-- Process the root task's children (the actual project tasks)
	tell application "OmniFocus"
		set projectTasks to tasks of topTasks
	end tell

	repeat with aTask in projectTasks
		my createReminder(targetList, aTask, missing value)
	end repeat

	log "  -> Done with project: " & listName
end processProject

------------------------------------------------------------------------
-- CORE: Process folders recursively
------------------------------------------------------------------------

on processFolder(aFolder, pathPrefix)
	tell application "OmniFocus"
		set folderName to name of aFolder
	end tell

	-- Build the hierarchical path
	if pathPrefix is "" then
		set currentPath to folderName
	else
		set currentPath to pathPrefix & " / " & folderName
	end if

	log "Processing folder: " & currentPath

	-- Process projects directly inside this folder
	tell application "OmniFocus"
		set folderProjects to projects of aFolder
	end tell

	repeat with proj in folderProjects
		my processProject(proj, currentPath)
	end repeat

	-- Recurse into subfolders
	tell application "OmniFocus"
		set subfolders to folders of aFolder
	end tell

	repeat with subfolder in subfolders
		my processFolder(subfolder, currentPath)
	end repeat
end processFolder

------------------------------------------------------------------------
-- MAIN
------------------------------------------------------------------------

on run
	-- Ensure both apps are running
	tell application "OmniFocus" to activate
	tell application "Reminders" to activate
	delay 1

	log "=== OmniFocus to Apple Reminders Sync ==="
	log "addCompletedTasks: " & addCompletedTasks
	log "dryRun: " & dryRun

	set taskCount to 0

	tell application "OmniFocus"
		set doc to default document

		-- 1) Process top-level projects (those not inside any folder)
		set topProjects to projects of doc whose folder is missing value

		-- 2) Process all folders (and their nested projects)
		set topFolders to folders of doc
	end tell

	-- Handle inbox items -> put them in a "OmniFocus Inbox" list
	tell application "OmniFocus"
		set doc to default document
		set inboxTasks to inbox tasks of doc
	end tell

	if (count of inboxTasks) > 0 then
		log "Processing Inbox..."
		set inboxList to my getOrCreateList("OmniFocus Inbox")
		repeat with aTask in inboxTasks
			my createReminder(inboxList, aTask, missing value)
		end repeat
		log "  -> Done with Inbox"
	end if

	-- Process top-level projects (no folder)
	repeat with proj in topProjects
		my processProject(proj, "")
	end repeat

	-- Process folders recursively
	repeat with aFolder in topFolders
		my processFolder(aFolder, "")
	end repeat

	log "=== Sync Complete ==="

	display dialog "OmniFocus to Reminders sync complete!" buttons {"OK"} default button "OK" with icon note
end run
