/* the scripts tab: device source is authoritative; localstorage holds unsaved work only. */
(function () {
  'use strict';
  const M = window.TC002ScriptsModel;
  const escape = text => text.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function highlight(source) {
    // highlight only; the original text is always edited and sent without transformation.
    const token = /(#.*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:def|end|var|if|elif|else|while|for|return|break|continue|import|as|class|static|try|except|raise|true|false|nil|and|or|not|in)\b|\b(?:0x[\da-fA-F]+|\d+(?:\.\d+)?)\b)/g;
    let out = '', at = 0;
    for (const match of source.matchAll(token)) {
      out += escape(source.slice(at, match.index));
      const text = match[0], kind = text[0] === '#' ? 'comment' : /["']/.test(text[0]) ? 'string' : /^\d/.test(text) ? 'number' : 'keyword';
      out += `<span class="script-${kind}">${escape(text)}</span>`;
      at = match.index + text.length;
    }
    return out + escape(source.slice(at)) + '\n';
  }
  class Editor {
    constructor(root, connection) {
      this.root = root; this.connection = connection; this.device = ''; this.session = null;
      this.active = false; this.generation = 0; this.entries = []; this.logNext = 0; this.logs = [];
      this.opening = false; this.polling = false;
      let storage = null;
      try { storage = window.localStorage; } catch {}
      this.storage = storage; this.drafts = new M.Drafts(storage);
      root.innerHTML = `
        <section class="card s12 scripts-card" id="scriptsCard">
          <h2>scripts <span id="scriptVm" class="pill">not connected</span></h2>
          <div class="script-layout">
            <aside class="script-sidebar" aria-label="script library">
              <div class="script-library-head"><strong>on this device</strong><button id="scriptRefresh" type="button">refresh</button></div>
              <div id="scriptBudget" class="hint"></div>
              <div id="scriptList" class="script-list" aria-label="scripts"></div>
              <form id="scriptNewForm" class="script-new">
                <label for="scriptName">new script name</label>
                <input id="scriptName" type="text" maxlength="32" placeholder="hello" autocomplete="off" spellcheck="false">
                <button id="scriptNew" type="submit">create local draft</button>
              </form>
              <p class="hint">drafts stay in this browser. only save writes to the device.</p>
            </aside>
            <div class="script-workspace">
              <div class="script-heading"><strong id="scriptTitle">select or create a script</strong><span id="scriptState" class="pill">no script</span></div>
              <div class="script-toolbar">
                <button id="scriptSave" type="button">save</button>
                <button id="scriptRun" type="button">run saved</button>
                <button id="scriptSaveRun" class="primary" type="button">save &amp; run</button>
                <button id="scriptDownload" type="button">download draft</button>
              </div>
              <div class="script-code">
                <pre id="scriptLines" aria-hidden="true">1</pre>
                <div class="script-code-body">
                  <pre id="scriptHighlight" aria-hidden="true"></pre>
                  <textarea id="scriptSource" aria-label="script source" spellcheck="false" autocapitalize="off" autocomplete="off" autocorrect="off" wrap="off" disabled></textarea>
                </div>
              </div>
              <div class="script-foot"><span id="scriptBytes">0 / 8000 bytes</span><span id="scriptPosition">line 1, column 1</span><span>⌘/ctrl+s saves · tab indents</span></div>
              <div id="scriptStorage" class="script-warning" role="status" hidden></div>
              <div id="scriptMessage" class="script-message" role="status" aria-live="polite"></div>
              <button id="scriptErrorLine" type="button" hidden>go to error line</button>
              <details id="scriptConflict" hidden><summary>compare with source on the device</summary><pre id="scriptRemote"></pre><button id="scriptOverwrite" type="button">overwrite device with this draft</button></details>
              <div class="script-secondary"><button id="scriptDiscard" type="button">discard local draft</button><button id="scriptDelete" class="danger" type="button">delete from device</button></div>
              <p id="scriptRunHint" class="hint">saving and running are separate. run saved uses the device version.</p>
            </div>
          </div>
          <details class="script-output" open><summary>script output <span id="scriptHeap" class="hint"></span></summary><p class="hint">the shared device log includes script prints, errors and other runtime messages.</p><pre id="scriptOutput" aria-label="script output">output appears here when a script prints or raises an error.</pre><button id="scriptClearOutput" type="button">clear view</button></details>
        </section>`;
      this.el = id => root.querySelector('#' + id);
      this.el('scriptSource').addEventListener('input', () => {
        if (!this.session) return;
        this.session.edit(this.el('scriptSource').value);
        this.message(''); this.renderState(); this.paint(); this.renderList();
      });
      this.el('scriptSource').addEventListener('scroll', () => this.scroll());
      this.el('scriptSource').addEventListener('click', () => this.position());
      this.el('scriptSource').addEventListener('keyup', () => this.position());
      this.el('scriptSource').addEventListener('keydown', event => this.keydown(event));
      this.el('scriptRefresh').onclick = () => this.activate();
      this.el('scriptNewForm').onsubmit = e => { e.preventDefault(); this.create(); };
      this.el('scriptSave').onclick = () => this.perform('save');
      this.el('scriptRun').onclick = () => this.perform('runSaved');
      this.el('scriptSaveRun').onclick = () => this.perform('saveAndRun');
      this.el('scriptOverwrite').onclick = () => this.confirm('scriptOverwrite', 'overwrite this device script?', () => this.perform('save', {overwrite:true}));
      this.el('scriptDiscard').onclick = () => this.confirm('scriptDiscard', 'discard this local draft?', () => this.discard());
      this.el('scriptDelete').onclick = () => this.confirm('scriptDelete', 'delete this device script?', () => this.remove());
      this.el('scriptDownload').onclick = () => this.download();
      this.el('scriptErrorLine').onclick = () => this.goToLine(this.errorLine);
      this.el('scriptClearOutput').onclick = () => { this.logs = []; this.renderLogs(); };
      window.addEventListener('beforeunload', e => {
        if (this.drafts.hasUnsafeDrafts() || this.session?.dirty && !this.session.durable) { e.preventDefault(); e.returnValue = ''; }
      });
      window.addEventListener('storage', event => {
        if (this.session && event.key === this.drafts.key(this.device, this.session.name)) {
          this.storageWarning('another tab changed this draft. your text is kept here; download it before closing this tab.');
          // an edit asks the storage model to detect the conflict and retain our text in memory.
          this.session.edit(this.session.source); this.renderList();
        }
      });
      this.timer = setInterval(() => { if (this.active && !document.hidden) this.poll(); }, 2000);
      this.renderState();
    }
    async request(device, method, path, body) {
      const options = {method, cache:'no-store'};
      if (body !== undefined) { options.body = body; options.headers = {'Content-Type':'text/plain; charset=utf-8'}; }
      const response = await fetch(`/api/${device}/v1/${path}`, options);
      const text = await response.text();
      if (!response.ok) {
        let detail; try { detail = JSON.parse(text); } catch {}
        const error = new Error(detail?.message || detail?.error || `request failed (${response.status})`);
        error.status = response.status; error.code = detail?.error; throw error;
      }
      if ((response.headers.get('content-type') || '').includes('json')) return text ? JSON.parse(text) : {};
      return text;
    }
    io(device) {
      const path = name => `berry/scripts/${encodeURIComponent(name)}`;
      return {
        read: async name => { try { return await this.request(device,'GET',path(name)); } catch(e) { if(e.status === 404 && e.code === 'not_found') return null; throw e; } },
        write: (name, source) => this.request(device,'PUT',path(name),source),
        run: name => this.request(device,'POST',path(name)+'/run'),
        remove: name => this.request(device,'DELETE',path(name)),
      };
    }
    message(text, bad = false) { this.el('scriptMessage').textContent = text; this.el('scriptMessage').classList.toggle('bad',bad); }
    storageWarning(text) { this.el('scriptStorage').textContent = text; this.el('scriptStorage').hidden = !text; }
    visible(active) { this.active = active; if (active) this.activate(); }
    async activate() {
      const connection = this.connection(), device = connection.device.trim();
      const generation = ++this.generation;
      if (this.device !== device) {
        this.device = device; this.session = null; this.entries = []; this.logs = []; this.logNext = 0;
        this.el('scriptSource').value = ''; this.paint(); this.renderLogs();
      }
      this.opening = true; this.renderState(); this.renderList();
      if (!device || !connection.control) {
        this.opening = false; this.message(device ? 'a control token is needed to read device scripts.' : 'enter a device address to open its scripts.',true); this.renderState(); return;
      }
      try {
        const list = await this.request(device,'GET','berry/scripts');
        if (generation !== this.generation) return;
        this.entries = list.scripts || [];
        this.el('scriptBudget').textContent = `${list.used} / ${list.budget ?? list.capacity} bytes on device`;
        this.renderList();
        let remembered;
        try { remembered = this.storage?.getItem(`tc002.script-selection:${device}`); } catch {}
        const names = this.names();
        const name = this.session?.name || (names.includes(remembered) ? remembered : names[0]);
        if (name) await this.open(name, generation);
        else this.message('no scripts yet. create a local draft to begin.');
      } catch (e) {
        if (generation !== this.generation) return;
        this.message(`cannot read scripts: ${e.message}. local drafts are still available.`,true);
        this.renderList();
      } finally {
        if (generation === this.generation) { this.opening = false; this.renderState(); this.poll(); }
      }
    }
    names() { return [...new Set([...this.entries.map(e => e.name), ...this.drafts.list(this.device).map(d => d.name)])].sort(); }
    renderList() {
      const list = this.el('scriptList'); list.replaceChildren();
      for (const name of this.names()) {
        const button = document.createElement('button'); button.type='button';
        button.className='script-entry'; button.setAttribute('aria-label',`open script ${name}`);
        button.setAttribute('aria-current',String(this.session?.name === name));
        const label = document.createElement('span'); label.textContent=name;
        const meta = document.createElement('small');
        const stored = this.entries.find(e => e.name === name), draft = this.drafts.get(this.device,name);
        meta.textContent = draft ? 'local draft' : stored ? `${stored.bytes} bytes` : 'local only';
        button.append(label,meta); button.onclick=() => this.open(name); list.append(button);
      }
    }
    async open(name, generation) {
      if (this.session?.busy) return;
      generation = generation ?? ++this.generation;
      const device = this.device;
      this.opening = true; this.renderState();
      try {
        const remote = await this.io(device).read(name);
        if (generation !== this.generation) return;
        this.session = new M.ScriptSession(this.drafts,device,name,remote,this.io(device));
        this.el('scriptSource').value = this.session.source;
        try { this.storage?.setItem(`tc002.script-selection:${device}`,name); } catch {}
        this.message(remote === null ? 'local draft — not yet stored on this device.' : '');
        this.paint(); this.renderList();
      } catch(e) {
        if (generation !== this.generation) return;
        const draft = this.drafts.get(device,name);
        if (draft) {
          this.session = new M.ScriptSession(this.drafts,device,name,draft.base,this.io(device));
          this.el('scriptSource').value = this.session.source; this.paint(); this.renderList();
        }
        this.message(`cannot read device source: ${e.message}. save will check again before writing.`,true);
      } finally { if (generation === this.generation) { this.opening=false; this.renderState(); } }
    }
    create() {
      const name=this.el('scriptName').value.trim();
      if (!this.device) return this.message('enter a device address first.',true);
      if (!M.validName(name)) return this.message('use 1–32 letters, digits, dots, dashes or underscores; do not start with a dot.',true);
      if (this.names().includes(name)) return this.message('that name already exists. open it from the list.',true);
      if (this.session?.busy) return;
      ++this.generation; this.opening=false;
      this.session=new M.ScriptSession(this.drafts,this.device,name,null,this.io(this.device));
      this.session.edit("# a new berry script\nprint('hello from berry')\n");
      this.el('scriptSource').value=this.session.source;
      this.el('scriptName').value='';
      try { this.storage?.setItem(`tc002.script-selection:${this.device}`,name); } catch {}
      this.message('local draft created. saving stores it; running is a separate action.');
      this.renderList(); this.renderState(); this.paint(); this.el('scriptSource').focus();
    }
    allowed() {
      const connection=this.connection();
      if (connection.device.trim() !== this.device) { this.message('the device address changed. refresh the script list first.',true); return false; }
      if (!connection.admin) { this.message('an admin token is needed to save, run or delete scripts.',true); return false; }
      return !!this.session && !this.opening && !this.session.busy;
    }
    async perform(method, options) {
      if (!this.allowed()) return;
      const session=this.session;
      if(method !== 'runSaved' && M.byteLength(session.source) > 8000) {
        this.message('a script is at most 8000 utf-8 bytes. the draft is kept in this browser.',true); return;
      }
      this.message(method === 'runSaved' ? 'running the saved device version…' : 'checking source on device…');
      this.el('scriptErrorLine').hidden=true;
      try {
        const pending=session[method](options); this.renderState();
        const result=await pending;
        if(this.session !== session) return;
        const didRun=method !== 'save';
        this.message(didRun ? 'script ran. output and errors appear below.' : result.written ? 'saved to device.' : 'already up to date — no device write.');
        if(method === 'save' && result.written && (result.response?.enabled === false || ['off','disabled'].includes(this.vmState))) {
          this.message('saved to device; scripting is disabled, so the source was not compiled.');
        }
        if (result?.response?.message) this.message(this.el('scriptMessage').textContent+' '+result.response.message);
        if(method !== 'runSaved') {
          const existing=this.entries.find(e=>e.name===session.name);
          if(existing) existing.bytes=M.byteLength(session.remote || '');
          else this.entries.push({name:session.name,bytes:M.byteLength(session.remote || '')});
        }
        this.poll();
      } catch(e) {
        if(this.session !== session) return;
        this.message(e.message,true);
        const line=e.message.match(/(?:line\s+|:)(\d+)(?::|\b)/i);
        this.errorLine=line ? Number(line[1]) : null; this.el('scriptErrorLine').hidden=!this.errorLine;
      } finally { if(this.session === session) { this.renderState(); this.renderList(); } }
    }
    confirm(id, prompt, action) {
      const button=this.el(id);
      if(button.dataset.armed === 'yes' && button.armedSession === this.session && button.armedSource === this.session?.source) {
        button.dataset.armed=''; button.textContent=button.dataset.label; action(); return;
      }
      if(button.dataset.armed !== 'yes') button.dataset.label=button.textContent;
      button.dataset.armed='yes'; button.armedSession=this.session; button.armedSource=this.session?.source;
      button.textContent=`${this.session?.name}: ${prompt}`;
      setTimeout(()=>{ if(button.dataset.armed === 'yes') {button.dataset.armed='';button.textContent=button.dataset.label;} },5000);
    }
    async discard() {
      const session=this.session; if(!session || session.busy || this.opening) return;
      const generation=++this.generation;
      this.opening=true; this.renderState();
      try {
        session.remote=await this.io(session.device).read(session.name);
        if(generation !== this.generation) return;
        session.discardDraft(); this.el('scriptSource').value=session.source;
        if(session.remote === null) this.session=null;
        this.message(session.remote === null ? 'local draft discarded.' : 'local draft discarded. source was reloaded from the device.');
        this.paint(); this.renderList();
      } catch(e) { if(generation === this.generation) this.message(`draft kept: ${e.message}`,true); }
      finally { if(generation === this.generation) {this.opening=false;this.renderState();} }
    }
    async remove() {
      if(!this.allowed()) return;
      const session=this.session;
      this.opening=true; this.renderState();
      try {
        await this.io(session.device).remove(session.name);
        if(this.session !== session) return;
        // keep a local recovery copy; deleting a stored script must not destroy the editor text.
        this.drafts.put(session.device,session.name,{source:session.source,base:null});
        this.session=new M.ScriptSession(this.drafts,session.device,session.name,null,this.io(session.device));
        this.entries=this.entries.filter(e=>e.name !== session.name);
        this.message('deleted from device. a local draft is kept in this browser.');
      } catch(e) { if(this.session === session) this.message(e.message,true); }
      finally { this.opening=false; this.renderState(); this.renderList(); }
    }
    download() {
      if(!this.session) return;
      const blob=new Blob([this.session.source],{type:'text/plain;charset=utf-8'}), url=URL.createObjectURL(blob);
      const a=document.createElement('a'); a.href=url; a.download=this.session.name+'.be'; a.click(); setTimeout(()=>URL.revokeObjectURL(url),1000);
    }
    renderState() {
      const s=this.session, connection=this.connection(), admin=connection.admin && connection.device.trim() === this.device;
      for(const id of ['scriptDelete','scriptDiscard','scriptOverwrite']) {
        const button=this.el(id);
        if(button.dataset.armed === 'yes' && (button.armedSession !== s || button.armedSource !== s?.source)) {
          button.dataset.armed=''; button.textContent=button.dataset.label;
        }
      }
      const busy=this.opening || s?.busy, size=s ? M.byteLength(s.source) : 0;
      this.el('scriptTitle').textContent=s ? s.name : 'select or create a script';
      this.el('scriptState').textContent=busy ? 'working…' : !s ? 'no script' : s.dirty ? 'local draft' : 'saved';
      this.el('scriptState').className='pill'+(s?.dirty ? ' warn' : '');
      this.el('scriptBytes').textContent=`${size} / 8000 bytes`;
      this.el('scriptBytes').classList.toggle('bad',size>8000);
      this.el('scriptSource').disabled=!s || this.opening;
      this.el('scriptSave').disabled=!s || busy || !admin || size>8000;
      this.el('scriptSaveRun').disabled=!s || busy || !admin || size>8000;
      this.el('scriptRun').disabled=!s || busy || !admin || s.remote===null;
      this.el('scriptDelete').disabled=!s || busy || !admin || s.remote===null;
      this.el('scriptDiscard').disabled=!s || busy;
      this.el('scriptDownload').disabled=!s;
      this.el('scriptRefresh').disabled=!!s?.busy;
      this.el('scriptNew').disabled=!!busy;
      this.el('scriptConflict').hidden=!s?.conflict;
      this.el('scriptOverwrite').disabled=busy || !admin || size>8000;
      this.el('scriptRemote').textContent=s?.remote ?? '(script is not on the device)';
      this.el('scriptRunHint').textContent=s?.name === 'autoexec' ? 'autoexec runs at interpreter startup. saving does not restart it; run saved executes it now.' : s?.dirty ? 'run saved uses the device version. your local changes remain a draft.' : 'saving and running are separate. run saved uses the device version.';
      if(this.drafts.error) this.storageWarning(this.drafts.error+' — download your draft before closing this tab.');
      else if(s?.dirty) this.storageWarning(s.durable ? '' : 'draft is only in memory. download it before closing this tab.');
      else this.storageWarning(this.drafts.hasUnsafeDrafts() ? 'another script or device has a draft only in memory. return to it and download it before closing this tab.' : '');
      this.position();
    }
    paint() {
      const text=this.el('scriptSource').value;
      this.el('scriptHighlight').innerHTML=highlight(text);
      this.el('scriptLines').textContent=Array.from({length:text.split('\n').length},(_,i)=>i+1).join('\n');
      this.scroll(); this.position();
    }
    scroll() {
      const source=this.el('scriptSource');
      this.el('scriptHighlight').scrollTop=source.scrollTop; this.el('scriptHighlight').scrollLeft=source.scrollLeft;
      this.el('scriptLines').scrollTop=source.scrollTop;
    }
    position() {
      const source=this.el('scriptSource'), before=source.value.slice(0,source.selectionStart), lines=before.split('\n');
      this.el('scriptPosition').textContent=`line ${lines.length}, column ${lines.at(-1).length+1}`;
    }
    keydown(event) {
      if((event.metaKey || event.ctrlKey) && event.key.toLowerCase()==='s') {event.preventDefault();this.perform('save');return;}
      if(event.key!=='Tab') return;
      event.preventDefault();
      const e=this.el('scriptSource'), start=e.selectionStart, end=e.selectionEnd;
      if(start === end && !event.shiftKey) e.setRangeText('  ',start,end,'end');
      else {
        const first=e.value.lastIndexOf('\n',start-1)+1;
        const last=end > start && e.value[end-1] === '\n' ? end-1 : end;
        const next=e.value.indexOf('\n',last), stop=next < 0 ? e.value.length : next;
        const block=e.value.slice(first,stop);
        const changed=block.split('\n').map(line=>event.shiftKey ? line.replace(/^ {1,2}|^\t/,'') : '  '+line).join('\n');
        e.setRangeText(changed,first,stop,'select');
        if(start === end) { const caret=Math.max(first,start-(block.length-changed.length));e.setSelectionRange(caret,caret); }
      }
      e.dispatchEvent(new Event('input',{bubbles:true}));
    }
    goToLine(line) {
      const e=this.el('scriptSource'), lines=e.value.split('\n');
      const start=lines.slice(0,Math.max(0,line-1)).reduce((n,text)=>n+text.length+1,0);
      e.focus(); e.setSelectionRange(start,start+(lines[line-1]?.length || 0)); e.scrollTop=Math.max(0,(line-3)*21); this.scroll();this.position();
    }
    async poll() {
      if(this.polling || !this.active || !this.device || !this.connection().control) return;
      this.polling=true; const device=this.device;
      try {
        const status=await this.request(device,'GET','berry');
        if(device!==this.device) return;
        this.vmState=status.state || (status.running ? 'running' : status.enabled ? 'starting' : 'disabled');
        this.el('scriptVm').textContent=this.vmState;
        this.el('scriptHeap').textContent=status.heap_bytes ? ` · heap ${status.heap_used} / ${status.heap_bytes} bytes` : '';
        const logs=await this.request(device,'GET',`logs?after=${this.logNext}`);
        if(device!==this.device) return;
        this.logNext=logs.next ?? this.logNext;
        for(const line of logs.lines || []) {
          const text=typeof line==='string' ? line : line.text || line.line || '';
          // the log ring has no source field: plain print output must not be filtered out.
          this.logs.push(text);
        }
        this.logs=this.logs.slice(-200); this.renderLogs();
      } catch(e) { if(device===this.device) this.el('scriptVm').textContent='status unavailable'; }
      finally { this.polling=false; }
    }
    renderLogs() { this.el('scriptOutput').textContent=this.logs.length ? this.logs.join('\n') : 'output appears here when a script prints or raises an error.'; }
  }
  window.TC002ScriptEditor={mount:(root,connection)=>new Editor(root,connection)};
})();
