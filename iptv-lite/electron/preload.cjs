const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('iptvDesktop', {
  getVersion: () => ipcRenderer.invoke('app:version')
});
