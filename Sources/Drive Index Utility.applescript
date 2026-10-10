-- External Drive Index (2 Levels + Root Folder Sizes + Drive Info)
-- Saves to: ~/Documents/External Drive Index/DriveName.txt (always overwrites)

on run
	
	-- Output folder in Documents
	set outDirPOSIX to (POSIX path of («event earsffdr» «constant afdrdocs»)) & "External Drive Index/"
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
	set mountPoint to "/Volumes/" & driveName
	set mountPointQ to quoted form of mountPoint
	
	-- Date inside file (MMDDYY)
	set dateStamp to «event sysoexec» "date +%m%d%y"
	
	-- Output file (always overwrites)
	set outPath to outDirPOSIX & driveName & ".txt"
	set outPathQ to quoted form of outPath
	
	-- Exclude macOS system folders
	set excludes to " ! -name '.' ! -name '.Spotlight-V100' ! -name '.Trashes' ! -name '.fseventsd' ! -name '.DocumentRevisions-V100' ! -name '.TemporaryItems' "
	
	-- Header: drive stats + diskutil metadata (overwrite file)
	-- We use diskutil info for identifiers/UUID/fs; df for space numbers.
	set headerCmd to "mp=" & mountPointQ & "; out=" & outPathQ & "; ds=" & quoted form of dateStamp & "; " & ¬
		"stats=$(df -H \"$mp\" 2>/dev/null | awk 'NR==2{print \"TOTAL: \"$2\"  USED: \"$3\"  AVAIL: \"$4\"  CAP: \"$5}'); " & ¬
		"duid=$(diskutil info \"$mp\" 2>/dev/null | awk -F': *' '/Device Identifier/{print $2}'); " & ¬
		"vuuid=$(diskutil info \"$mp\" 2>/dev/null | awk -F': *' '/Volume UUID/{print $2}'); " & ¬
		"fst=$(diskutil info \"$mp\" 2>/dev/null | awk -F': *' '/Type \\(Bundle\\)|File System Personality/{print $2; exit}'); " & ¬
		"vname=$(diskutil info \"$mp\" 2>/dev/null | awk -F': *' '/Volume Name/{print $2}'); " & ¬
		"proto=$(diskutil info \"$mp\" 2>/dev/null | awk -F': *' '/Protocol/{print $2}'); " & ¬
		"dname=$(diskutil info \"$mp\" 2>/dev/null | awk -F': *' '/Disk \\/ Partition UUID/{next} /Media Name|Device \\/ Media Name/{print $2; exit}'); " & ¬
		"printf '%s
' \"DRIVE: " & driveName & "    INDEX DATE: $ds\" > \"$out\"; " & ¬
		"printf '%s
' '========================================' >> \"$out\"; " & ¬
		"printf '%s
' \"MOUNT: $mp\" >> \"$out\"; " & ¬
		"if [ -n \"$duid\" ]; then printf '%s
' \"IDENTIFIER: $duid\" >> \"$out\"; fi; " & ¬
		"if [ -n \"$vname\" ]; then printf '%s
' \"VOLUME NAME: $vname\" >> \"$out\"; fi; " & ¬
		"if [ -n \"$vuuid\" ]; then printf '%s
' \"VOLUME UUID: $vuuid\" >> \"$out\"; fi; " & ¬
		"if [ -n \"$fst\" ]; then printf '%s
' \"FILE SYSTEM: $fst\" >> \"$out\"; fi; " & ¬
		"if [ -n \"$proto\" ]; then printf '%s
' \"PROTOCOL: $proto\" >> \"$out\"; fi; " & ¬
		"if [ -n \"$dname\" ]; then printf '%s
' \"MEDIA NAME: $dname\" >> \"$out\"; fi; " & ¬
		"if [ -n \"$stats\" ]; then printf '%s
' \"$stats\" >> \"$out\"; fi; " & ¬
		"printf '
' >> \"$out\""
	
	-- Body: 2 levels of folders, root sizes only
	set bodyCmd to "cd " & mountPointQ & " && " & ¬
		"find . -maxdepth 1 -type d " & excludes & " 2>/dev/null " & ¬
		"| sed 's|^\\./||' | sed '/^$/d' | sort " & ¬
		"| while IFS= read -r root; do " & ¬
		"  [ -z \"$root\" ] && continue; " & ¬
		"  rsize=$(du -sh \"./$root\" 2>/dev/null | awk '{print $1}'); " & ¬
		"  [ -z \"$rsize\" ] && rsize='?'; " & ¬
		"  printf '%s
' \"$root  [$rsize]\"; " & ¬
		"  find \"./$root\" -maxdepth 1 -mindepth 1 -type d " & excludes & " 2>/dev/null " & ¬
		"    | sed 's|^\\./||' | sed \"s|^$root/||\" | sed '/^$/d' | sort " & ¬
		"    | while IFS= read -r sub; do " & ¬
		"        [ -z \"$sub\" ] && continue; " & ¬
		"        printf '%s
' \"|-- $sub\"; " & ¬
		"      done; " & ¬
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
	
	-- Reveal output folder
	«event sysoexec» "open " & quoted form of outDirPOSIX
	
end run

