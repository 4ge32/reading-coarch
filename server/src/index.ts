import { buildApp } from './app.js';
import { readConfig } from './config.js';

try {
  const config = readConfig();
  const app = await buildApp(config);
  await app.listen({host: config.HOST, port: config.PORT});
  console.info(`ReadingCoach backend listening; mode=${config.PROVIDER_MODE}, TLS=${Boolean(config.TLS_CERT_FILE)}`);
  const shutdown = async () => {await app.close(); process.exit(0);};
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
} catch {
  console.error('Backend startup failed. Check configuration, TLS file paths, and listen address.');
  process.exitCode = 1;
}
