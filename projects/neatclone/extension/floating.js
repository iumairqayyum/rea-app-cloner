// Injected into the isolated extension world only after explicit site approval.
export function floatingMediaControls(candidates) {
  document.getElementById('neatclone-media-controls')?.remove();
  if (!candidates.length) return;
  const host = document.createElement('aside'); host.id = 'neatclone-media-controls';
  Object.assign(host.style, {position: 'fixed', right: '14px', bottom: '14px', zIndex: '2147483647'});
  const shadow = host.attachShadow({mode: 'closed'});
  const panel = document.createElement('div');
  Object.assign(panel.style, {font: '13px system-ui', background: '#20242a', color: '#fff', padding: '10px', borderRadius: '8px', maxWidth: '280px'});
  const title = document.createElement('strong'); title.textContent = 'NeatClone media'; panel.append(title);
  const close = document.createElement('button'); close.textContent = 'Close'; close.addEventListener('click', event => {if (event.isTrusted) host.remove();}); panel.append(close);
  const select = document.createElement('select'); select.style.display = 'block'; select.style.maxWidth = '260px';
  for (const candidate of candidates) {
    const option = document.createElement('option'); option.value = candidate.id;
    option.textContent = `${candidate.kind.toUpperCase()} · ${candidate.quality ? candidate.quality + 'p' : 'quality unknown'} · ${candidate.source}`;
    select.append(option);
  }
  panel.append(select);
  const send = document.createElement('button'); send.textContent = 'Send selected media';
  const status = document.createElement('div'); status.setAttribute('role', 'status');
  send.addEventListener('click', async event => {
    if (!event.isTrusted) return;
    send.disabled = true;
    try {
      const reply = await chrome.runtime.sendMessage({action: 'floatingSend', candidateID: select.value});
      status.textContent = reply?.ok ? 'Request received by NeatClone.' : 'Not sent. Open the extension popup to authorize this media site.';
    } catch {status.textContent = 'Native host unavailable. Open the NeatClone popup.';}
    send.disabled = false;
  });
  panel.append(send, status); shadow.append(panel); document.documentElement.append(host);
}
