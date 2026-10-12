(() => {
  let sequence = 0;
  const pending = new Map();
  const defaultTimeoutMs = 5 * 60 * 1000;
  const modelDownloadTimeoutMs = 30 * 60 * 1000;

  function request(method, params = {}) {
    return new Promise((resolve, reject) => {
      if (typeof method !== 'string' || !method || !params || typeof params !== 'object') {
        reject(Object.assign(new Error('Invalid native request.'), { code: 'invalid_request' }));
        return;
      }
      const channel = window.MiyinApp;
      if (!channel || typeof channel.postMessage !== 'function') {
        reject(Object.assign(new Error('本机功能只在觅音手机应用中可用。'), { code: 'native_unavailable' }));
        return;
      }

      const id = `${Date.now().toString(36)}-${(++sequence).toString(36)}`;
      const timeoutMs = method === 'translation.downloadModel' ? modelDownloadTimeoutMs : defaultTimeoutMs;
      const timer = window.setTimeout(() => {
        pending.delete(id);
        reject(Object.assign(new Error('本机操作超时，请检查设备状态后重试。'), { code: 'request_timeout' }));
      }, timeoutMs);
      pending.set(id, { resolve, reject, timer });
      try {
        channel.postMessage(JSON.stringify({ version: 1, id, method, params }));
      } catch (error) {
        window.clearTimeout(timer);
        pending.delete(id);
        reject(Object.assign(new Error('无法连接本机功能。'), { code: 'native_unavailable', cause: error }));
      }
    });
  }

  function receive(response) {
    if (!response || response.version !== 1 || typeof response.id !== 'string') return;
    const request = pending.get(response.id);
    if (!request) return;
    pending.delete(response.id);
    window.clearTimeout(request.timer);
    if (response.ok === true) {
      request.resolve(response.result);
      return;
    }
    const details = response.error && typeof response.error === 'object' ? response.error : {};
    request.reject(Object.assign(
      new Error(typeof details.message === 'string' ? details.message : '本机操作失败。'),
      { code: typeof details.code === 'string' ? details.code : 'operation_failed' },
    ));
  }

  window.MiyinNativeBridge = Object.freeze({ request, receive });
})();
