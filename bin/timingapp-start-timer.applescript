-- from <https://timingapp.com/help/applescript-adding-time-entry>

on run argv
    tell application "TimingHelper"
    	if not scripting support available then
    		error "This script requires a Timing Expert subscription. Please contact support via https://timingapp.com/contact to upgrade."
    	end if
    end tell

    tell application "TimingHelper"
    	set pr to front project whose name is item 1 of argv
    	start timer with title item 2 of argv project pr for about 3600
    end tell
end run
