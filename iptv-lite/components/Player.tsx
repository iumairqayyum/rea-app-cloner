'use client';
import { useEffect, useRef, useState } from 'react';
import Hls from 'hls.js';
import type { Channel } from '@/lib/channels';

export default function Player({ channel }: { channel: Channel | null }) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [status, setStatus] = useState('Choose a channel');
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !channel) { setStatus('Choose a channel'); return; }
    if (!channel.streamUrl) { setStatus('Add a playlist to start watching'); return; }
    let hls: Hls | undefined;
    setStatus('Connecting…');
    if (Hls.isSupported()) {
      hls = new Hls({ enableWorker: true, lowLatencyMode: true });
      hls.loadSource(channel.streamUrl); hls.attachMedia(video);
      hls.on(Hls.Events.MANIFEST_PARSED, () => { setStatus('Live'); void video.play().catch(() => setStatus('Press play to start')); });
      hls.on(Hls.Events.ERROR, (_event, data) => { if (data.fatal) setStatus('Stream unavailable'); });
    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = channel.streamUrl; video.play().catch(() => setStatus('Press play to start')); setStatus('Live');
    } else setStatus('HLS playback is not supported in this browser');
    return () => { hls?.destroy(); video.pause(); video.removeAttribute('src'); video.load(); };
  }, [channel]);
  return <div className="screen"><video ref={videoRef} controls playsInline /><div className="screen-overlay"><span className="live-dot" />{status}</div>{channel && <div className="now-playing"><div className="channel-mark">{channel.logo}</div><div><small>NOW PLAYING</small><strong>{channel.name}</strong></div></div>}</div>;
}
