#!/bin/bash
# BEA-689 Obsidian CLI-bridge probe (reproducible). Obsidian stays in the background.
# Creates latch-probe-scratch.md in a background tab, tests criteria 1-4 via `obsidian eval`,
# then closes the tab and deletes the note. Needs Obsidian running with the CLI enabled.
set -u
E(){ timeout 15 obsidian eval code="$1" 2>&1; }
front(){ osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'; }
echo "front before: $(front)"
E "(async()=>{const a=app.workspace.activeLeaf; window.__lp={prev:a&&a.id}; const f=await app.vault.create('latch-probe-scratch.md','alpha beta '); const l=app.workspace.getLeaf('tab'); await l.openFile(f,{active:false}); window.__lp.leaf=l.id; if(a) app.workspace.setActiveLeaf(a,{focus:false}); return JSON.stringify({prev:a&&a.id,leaf:l.id,active:app.workspace.activeLeaf.id})})()"
E "(()=>{const l=app.workspace.getLeafById(window.__lp.leaf); const ed=l.view.editor; ed.setCursor({line:0,ch:11}); const pos=ed.getCursor(); const ctx=ed.getRange({line:0,ch:0},pos); ed.replaceRange('[cli1]',pos); const p2=ed.offsetToPos(ed.posToOffset(pos)+6); ed.replaceRange(' [cli2]',p2); return JSON.stringify({ctxBefore:ctx,value:ed.getValue(),cursor:ed.getCursor(),activeLeaf:app.workspace.activeLeaf.id})})()"
sleep 2.5; echo "disk: $(cat "$HOME/Obsidian_Vaults/Second Brain/latch-probe-scratch.md")"
E "(()=>{const ed=app.workspace.getLeafById(window.__lp.leaf).view.editor; ed.undo(); const a=ed.getValue(); ed.redo(); return JSON.stringify({afterUndo:a,afterRedo:ed.getValue()})})()"
E "(async()=>{const l=app.workspace.getLeafById(window.__lp.leaf); const f=l.view.file; l.detach(); const lost=!app.workspace.getLeafById(window.__lp.leaf); await app.vault.delete(f); delete window.__lp; return JSON.stringify({lostDetected:lost,fileGone:!app.vault.getAbstractFileByPath('latch-probe-scratch.md')})})()"
echo "front after: $(front)"
