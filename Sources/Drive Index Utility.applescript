-- Archival Drive Index (2 Levels)
-- Silent version (no completion popup)
-- Overwrites: ~/Documents/Archival Drive Indexes/DriveName.txt

on run
	
	-- Output folder in Documents
	set outDirPOSIX to (POSIX path of («event earsffdr» «constant afdrdocs»)) & "Archival Drive Indexes/"
	«event sysoexec» "mkdir -p " & quoted form of outDirPOSIX
	
	-- Get mounted volumes
	set volNames to paragraphs of («event sysoexec» "ls -1 /Volumes | sed '/^\\./d' || true")
	if volNames is {} then
		«event sysodisA» "No drives found" given «class mesS»:"No mounted volumes detected.", «class as A»:«constant EAlTcriT»
		return
	end if
	
	-- Select drive
	set chosenVol to «event gtqpchlt» volNames given «class appr»:"Select Drive", «class prmp»:"Choose a mounted drive to index:", «class okbt»:"Generate", «class cnbt»:"Cancel"
	if chosenVol is false then return
	
	set driveName to item 1 of chosenVol
	set drivePathQ to quoted form of ("/Volumes/" & driveName)
	
	-- Date inside file (MMDDYY)
	set dateStamp to «event sysoexec» "date +%m%d%y"
	
	-- Output file (always overwrites)
	set outPath to outDirPOSIX & driveName & ".txt"
	set outPathQ to quoted form of outPath
	
	-- Exclude macOS system folders
	set excludes to " ! -name '.' ! -name '.Spotlight-V100' ! -name '.Trashes' ! -name '.fseventsd' ! -name '.DocumentRevisions-V100' ! -name '.TemporaryItems' "
	
	-- Header (overwrite file)
	set headerCmd to "printf '%s
' " & quoted form of ("DRIVE: " & driveName & "    INDEX DATE: " & dateStamp) & " > " & outPathQ & "; " & ¬
		"printf '%s
' '========================================' >> " & outPathQ & "; " & ¬
		"printf '%s

' '' >> " & outPathQ
	
	-- Body (2 levels only)
	set bodyCmd to "cd " & drivePathQ & " && " & ¬
		"find . -maxdepth 1 -type d " & excludes & " 2>/dev/null " & ¬
		"| sed 's|^\\./||' | sed '/^$/d' | sort " & ¬
		"| while IFS= read -r root; do " & ¬
		"  printf '%s
' \"$root\"; " & ¬
		"  find \"./$root\" -maxdepth 1 -mindepth 1 -type d " & excludes & " 2>/dev/null " & ¬
		"    | sed 's|^\\./||' | sed \"s|^$root/||\" | sed '/^$/d' | sort " & ¬
		"    | while IFS= read -r sub; do printf '%s
' \"|-- $sub\"; done; " & ¬
		"  printf '
'; " & ¬
		"done >> " & outPathQ & " || true"
	
	try
		«event sysoexec» headerCmd
		«event sysoexec» bodyCmd
	on error errMsg number errNum
		«event sysodisA» "Failed" given «class mesS»:("Error " & errNum & ":
" & errMsg), «class as A»:«constant EAlTcriT»
		return
	end try
	
	-- Reveal output folder (optional – remove this line if you want fully silent)
	«event sysoexec» "open " & quoted form of outDirPOSIX
	
end run

