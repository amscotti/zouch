const PouchDB = require('pouchdb');
PouchDB.plugin(require('pouchdb-adapter-memory'));
const base = process.env.ZOUCH || 'http://127.0.0.1:5985';
const remote = base + '/pouch_test';

async function main() {
  await fetch(remote, { method: 'DELETE' }).catch(() => {});
  const created = await fetch(remote, { method: 'PUT' });
  if (!created.ok && created.status !== 412) throw new Error('create db: ' + created.status);

  const local = new PouchDB('zouch-pouch-local', { adapter: 'memory' });
  const docs = [];
  for (let i = 0; i < 20; i++) docs.push({ _id: `d${i}`, n: i });
  await local.bulkDocs(docs);

  const push = await local.replicate.to(remote);
  if (!push.ok) throw new Error('push failed: ' + JSON.stringify(push));

  const r = new PouchDB(remote);
  const all = await r.allDocs({ include_docs: true });
  if (all.rows.length !== 20) throw new Error('remote rows ' + all.rows.length);

  const pulled = new PouchDB('zouch-pouch-pull', { adapter: 'memory' });
  const pull = await r.replicate.to(pulled);
  if (!pull.ok) throw new Error('pull failed: ' + JSON.stringify(pull));
  const back = await pulled.allDocs();
  if (back.rows.length !== 20) throw new Error('pull rows ' + back.rows.length);

  const d = await local.get('d7');
  d.n = 700;
  await local.put(d);
  await local.replicate.to(remote);
  const rd = await r.get('d7');
  if (rd.n !== 700) throw new Error('update did not replicate: ' + rd.n);

  const conflicts = await r.get('d7', { conflicts: true });
  if (conflicts._conflicts) throw new Error('unexpected conflict');

  await local.destroy();
  await pulled.destroy();
  await r.destroy();
  console.log('PASS: PouchDB pushed 20 docs, pulled 20 docs, and replicated an update');
}

main().catch(e => { console.error(e); process.exit(1); });
