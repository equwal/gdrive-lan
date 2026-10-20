// Public demo: replaces fetch with an in-memory fake of the rclone rc calls index.html makes.
// Nothing leaves the browser. demo.html is index.html plus <script src="demo.js"> before its own script.
const GB = 1 << 30, MB = 1 << 20;
const files = {            // fake files on "g": path -> size, a trailing / marks a folder
  "/mnt/4tb/": 0, "/mnt/4tb/book-downloads/": 0, "/mnt/4tb/book-downloads/foo/": 0,
  "/mnt/4tb/book-downloads/foo/a.epub": 3 * MB, "/mnt/4tb/book-downloads/foo/b.epub": 5 * MB,
  "/mnt/4tb/book-downloads/bar/": 0, "/mnt/4tb/book-downloads/bar/c.pdf": 900 * MB,
  "/mnt/4tb/movies/": 0, "/mnt/4tb/movies/film.mkv": 4 * GB,
};
const jobs = [];           // {id, group, start, total, ms, stopped}
const size = p => Object.entries(files).filter(([k]) => k === p || k.startsWith(p + "/")).reduce((s, [, v]) => s + v, 0);
const isDir = p => files[p + "/"] !== undefined;
const exists = p => isDir(p) || files[p] !== undefined;
const state = j => j.stopped ? "stopped" : Date.now() - j.start >= j.ms ? "done" : "running";
const add = (group, total, ms, ago = 0) => jobs.push({ id: jobs.length + 1, group, start: Date.now() - ago, total, ms, stopped: false });
add("gcrypt:book-downloads/old", 2 * GB, 30000, 120000);   // one finished upload to start with

function call(method, p) {
  const j = jobs.find(x => x.id === p.jobid), g = jobs.find(x => x.group === p.group);
  switch (method) {
    case "operations/stat": {
      const path = (p.fs.replace(/\/$/, "") + "/" + p.remote);
      return { item: exists(path) ? { IsDir: isDir(path), Name: p.remote } : null };
    }
    case "operations/mkdir": return {};
    case "operations/list": {
      const d = p.fs.replace(/\/?$/, "/");
      const kids = Object.keys(files).filter(k => k.startsWith(d) && k !== d && k.endsWith("/") && !k.slice(d.length, -1).includes("/"));
      return { list: kids.map(k => ({ Path: k.slice(d.length, -1), IsDir: true })) };
    }
    case "operations/about": return { used: 41 * GB, free: 74 * GB, total: 115 * GB };
    case "sync/copy": case "operations/copyfile": {
      const src = method === "sync/copy" ? p.srcFs : p.srcFs.replace(/\/$/, "") + "/" + p.srcRemote;
      add(p._group, size(src) || 50 * MB, Math.max(8000, size(src) / (40 * MB) * 1000));
      return { jobid: jobs.length };
    }
    case "job/list": return { runningIds: jobs.filter(x => state(x) === "running").map(x => x.id) };
    case "job/status": return { group: j.group, finished: state(j) !== "running" };
    case "core/group-list": return { groups: jobs.map(x => x.group) };
    case "core/stats": {
      const t = Date.now() - g.start, run = state(g) === "running", done = state(g) === "done";
      const bytes = Math.min(g.total, g.total * t / g.ms);
      return { bytes, totalBytes: g.total, speed: g.total / g.ms * 1000, eta: run ? (g.ms - t) / 1000 : null,
        errors: g.stopped ? 1 : 0, lastError: g.stopped ? "context canceled" : "" };
    }
    case "job/stopgroup": g.stopped = true; return {};
  }
  throw Error("not in the demo: " + method);
}

window.fetch = async (url, o) => {
  try { return new Response(JSON.stringify(call(String(url).replace(/^\//, ""), JSON.parse(o.body || "{}"))), { status: 200 }); }
  catch (e) { return new Response(JSON.stringify({ error: e.message }), { status: 500 }); }
};

document.addEventListener("DOMContentLoaded", () => {
  document.body.insertAdjacentHTML("afterbegin",
    '<p style="padding:6px 8px;border:1px solid #888;border-radius:4px">Demo with fake data: nothing is uploaded. ' +
    'Try <code>/mnt/4tb/book-downloads/foo</code>. <a href="https://github.com/equwal/gdrive-lan">Source</a></p>');
  document.querySelector('a[href="/[gcrypt:]/"]').onclick = e => { e.preventDefault(); document.getElementById("msg").textContent = "No drive to browse in the demo"; };
});
