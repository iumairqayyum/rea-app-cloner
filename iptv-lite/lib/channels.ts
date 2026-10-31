export type Channel = { id: string; name: string; category: string; logo: string; streamUrl: string };
// UI placeholders. Replace with channels parsed from a user-selected M3U playlist.
export const channels: Channel[] = [
  { id: 'world', name: 'World News', category: 'News', logo: 'WN', streamUrl: '' },
  { id: 'city', name: 'City Life', category: 'Lifestyle', logo: 'CL', streamUrl: '' },
  { id: 'field', name: 'The Field', category: 'Sports', logo: 'TF', streamUrl: '' },
  { id: 'cinema', name: 'Cinema One', category: 'Movies', logo: 'C1', streamUrl: '' },
  { id: 'science', name: 'Science Daily', category: 'Documentary', logo: 'SD', streamUrl: '' },
  { id: 'music', name: 'Pulse Music', category: 'Music', logo: 'PM', streamUrl: '' },
  { id: 'global', name: 'Global 24', category: 'News', logo: 'G24', streamUrl: '' },
  { id: 'arena', name: 'Arena+', category: 'Sports', logo: 'A+', streamUrl: '' },
];
