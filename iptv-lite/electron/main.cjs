const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('node:path');
const isDev = !app.isPackaged;

function createWindow() {
  const win = new BrowserWindow({
    width: 1440, height: 900, minWidth: 960, minHeight: 640,
    backgroundColor: '#090d13',
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false }
  });
  if (isDev) win.loadURL('http://127.0.0.1:3000');
  else win.loadFile(path.join(__dirname, '../out/index.html'));
}

ipcMain.handle('app:version', () => app.getVersion());
app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
