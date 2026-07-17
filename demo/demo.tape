# VHS tape for demo.gif — run from the repo root: vhs demo/demo.tape
# Uses the stub test harness (see demo/env.sh); no AWS account or Docker
# daemon involved.

Output demo/demo.gif

Set Shell bash
Set FontSize 16
Set Width 1280
Set Height 640
Set Padding 12
Set TypingSpeed 60ms

Hide
Type "source demo/env.sh && clear"
Enter
Sleep 1s
Show

Type "rdsclient -t Environment=production"
Sleep 500ms
Enter
Sleep 2.5s

Type "2"
Sleep 500ms
Enter
Sleep 3s

Type "select 1;"
Sleep 500ms
Enter
Sleep 2s

Type "\q"
Sleep 500ms
Enter
Sleep 1.5s
