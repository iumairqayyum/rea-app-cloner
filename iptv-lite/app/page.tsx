'use client';
import { useMemo, useState } from 'react';
import Player from '@/components/Player';
import { channels, type Channel } from '@/lib/channels';

const categories = ['All channels', ...Array.from(new Set(channels.map(c => c.category)))];
export default function Home() {
  const [selected, setSelected] = useState<Channel | null>(null);
  const [category, setCategory] = useState('All channels');
  const [query, setQuery] = useState('');
  const visible = useMemo(() => channels.filter(c => (category === 'All channels' || c.category === category) && c.name.toLowerCase().includes(query.toLowerCase())), [category, query]);
  return <main className="app-shell">
    <aside className="sidebar"><div className="brand"><span className="brand-icon">◉</span><span>LUMA<span className="brand-light"> TV</span></span></div><div className="side-label">LIBRARY</div><button className="nav-item active">▦ <span>Live TV</span><b>{channels.length}</b></button><button className="nav-item">☆ <span>Favorites</span></button><button className="nav-item">◷ <span>Recently watched</span></button><div className="side-bottom"><div className="playlist-card"><div className="playlist-icon">＋</div><strong>Your playlist</strong><p>Connect an M3U playlist to load your channels.</p><button onClick={() => document.getElementById('playlist-input')?.click()}>Add playlist</button><input id="playlist-input" type="file" accept=".m3u,.m3u8" hidden /></div><div className="profile"><div className="avatar">G</div><div><strong>Guest profile</strong><small>Local library</small></div><span>•••</span></div></div></aside>
    <section className="main-area"><header className="topbar"><div><span className="breadcrumb">LIBRARY</span><span className="crumb-sep">/</span><strong>Live TV</strong></div><div className="top-actions"><span className="connection"><i /> Local mode</span><button className="icon-button" aria-label="Settings">⚙</button></div></header>
      <div className="content"><div className="welcome"><div><div className="eyebrow">YOUR SCREEN, YOUR WAY</div><h1>Good evening<span>.</span></h1><p>Pick up where you left off or find something to watch.</p></div><div className="date-chip">◷ <span>LIVE CHANNELS</span></div></div>
        <div className="player-layout"><div className="player-column"><Player channel={selected} /><div className="player-meta"><div><span className="eyebrow">{selected ? selected.category.toUpperCase() : 'FEATURED'}</span><h2>{selected?.name ?? 'Your entertainment, in one place'}</h2></div><button className="favorite-button">☆ <span>Save</span></button></div></div>
        <section className="channel-panel"><div className="panel-heading"><div><h3>Channels</h3><p>{visible.length} channels available</p></div><button className="more-button">•••</button></div><label className="search"><span>⌕</span><input placeholder="Search channels" value={query} onChange={e => setQuery(e.target.value)} /><kbd>⌘ K</kbd></label><div className="category-row">{categories.map(c => <button key={c} className={category === c ? 'category selected' : 'category'} onClick={() => setCategory(c)}>{c}</button>)}</div><div className="channel-list">{visible.map((c, i) => <button key={c.id} onClick={() => setSelected(c)} className={`channel-row ${selected?.id === c.id ? 'chosen' : ''}`}><span className={`channel-logo logo-${i % 5}`}>{c.logo}</span><span className="channel-info"><strong>{c.name}</strong><small>{c.category}</small></span><span className="channel-live"><i /> LIVE</span><span className="row-more">•••</span></button>)}{visible.length === 0 && <p className="empty">No channels found.</p>}</div><div className="panel-footer"><span><i className="live-dot" /> Broadcast status</span><strong>Ready</strong></div></section></div>
      </div><footer className="footer"><span> LUMA TV <b>·</b> A personal media library</span><span>Playback availability depends on your source.</span></footer>
    </section>
  </main>;
}
