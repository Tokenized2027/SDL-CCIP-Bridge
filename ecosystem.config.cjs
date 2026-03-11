module.exports = {
  apps: [
    {
      name: 'bridge-ai',
      cwd: __dirname + '/platform',
      script: 'bridge_analyze_endpoint.py',
      interpreter: __dirname + '/platform/.venv/bin/python',
      autorestart: true,
      max_restarts: 10,
      min_uptime: '10s',
      restart_delay: 5000,
      kill_timeout: 3000,
      max_memory_restart: '300M',
      env: {
        PYTHONUNBUFFERED: '1',
        PORT: '5050',
      },
    },
  ],
};
