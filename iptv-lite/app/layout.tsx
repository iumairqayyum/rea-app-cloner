import type { Metadata } from 'next';
import './globals.css';
export const metadata: Metadata = { title: 'Luma TV', description: 'A lightweight IPTV library and player' };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
