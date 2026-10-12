"""HTTP checks against the gateway, run by tools/verify.sh inside a throwaway client container.

usage: probe.py <base-url> <checks>    checks: comma list of
  page, results, opensearch, image-proxy, autocomplete, defaults, forbidden, search-once
Prints one PASS/FAIL line per check; exit code = number of failures.
"""
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = sys.argv[1].rstrip("/")
CHECKS = sys.argv[2].split(",")
FAILS = 0


def get(path, host=None, timeout=60):
    req = urllib.request.Request(BASE + path, headers={"User-Agent": "Mozilla/5.0 searxng-lan-verify",
                                                        "Accept-Language": "en"})
    if host:
        req.add_header("Host", host)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def check(name, ok, detail=""):
    global FAILS
    print(f"{'PASS' if ok else 'FAIL'} {name}" + (f" ({detail})" if detail else ""))
    FAILS += 0 if ok else 1


def engines(html):
    names = set()
    for block in re.findall(r'class="engines">(.*?)</div>', html, re.S):
        names.update(n.strip().lower() for n in re.findall(r"<span>([^<]+)</span>", block))
    return names


def search(path, want, tries=3):
    """Engines get rate-limited now and then: retry a few times before judging."""
    for attempt in range(tries):
        status, html = get(path)
        if status == 200 and want(html):
            return status, html
        time.sleep(5 * (attempt + 1))
    return status, html


for c in CHECKS:
    if c == "page":
        status, html = get("/")
        check("search page served to an allowed client", status == 200 and 'id="search"' in html and "SearXNG" in html,
              f"HTTP {status}")
    elif c == "forbidden":
        status, _ = get("/")
        check("403 for a client outside the allowed networks", status == 403, f"HTTP {status}")
    elif c == "results":
        status, html = search("/search?q=debian+linux", lambda h: len(engines(h)) >= 3)
        found = sorted(engines(html))
        check("results from at least 3 engines", len(found) >= 3, f"HTTP {status}, engines: {', '.join(found) or 'none'}")
    elif c == "search-once":
        status, html = get("/search?q=wikipedia")
        check("a search returns a results page", status == 200 and 'id="results"' in html, f"HTTP {status}")
    elif c == "opensearch":
        ok, notes = True, []
        for host in ("dappnode.local:8080", "192.0.2.10:8090"):
            status, xml = get("/opensearch.xml", host=host)
            want = f'template="http://{host}/search?q={{searchTerms}}"'
            hit = status == 200 and want in xml and 'method="GET"' in xml
            ok &= hit
            notes.append(f"{host}: {'echoed' if hit else 'MISSING'}")
        status, html = get("/")
        link = 'rel="search"' in html and "application/opensearchdescription+xml" in html
        ok &= link
        notes.append("autodiscovery link " + ("present" if link else "MISSING"))
        check("OpenSearch: GET search URL built for the address the device used", ok, "; ".join(notes))
    elif c == "image-proxy":
        status, html = search("/search?q=cat&categories=images", lambda h: "image_proxy?url=" in h)
        srcs = re.findall(r'src="([^"]+)"', html)
        proxied = [s for s in srcs if "image_proxy?url=" in s]
        external = [s for s in srcs if s.startswith("http") and "image_proxy" not in s]
        check("thumbnails load through the instance (image proxy)", bool(proxied) and not external,
              f"{len(proxied)} proxied, {len(external)} direct third-party")
    elif c == "image-sample":
        # One proxied thumbnail link: url + h (= HMAC of url with the instance's secret). Both are public.
        status, html = search("/search?q=cat&categories=images", lambda h: "image_proxy?url=" in h)
        src = next((s for s in re.findall(r'src="([^"]+)"', html) if "image_proxy?url=" in s), "")
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(src.replace("&amp;", "&")).query)
        sample = {"url": q.get("url", [""])[0], "h": q.get("h", [""])[0]}
        print("SAMPLE " + json.dumps(sample))
        check("got a proxied thumbnail link", bool(sample["url"] and sample["h"]), f"HTTP {status}")
    elif c == "autocomplete":
        status, body = get("/autocompleter?q=debi")
        try:
            data = json.loads(body) if body.strip() else []
        except ValueError:
            data = None
        # OpenSearch suggestions format: [query, [suggestions], ...]
        suggestions = data[1] if isinstance(data, list) and len(data) >= 2 and isinstance(data[1], list) else data
        check("autocomplete returns no suggestions", status in (200, 204, 400) and not suggestions, f"HTTP {status}, {body[:60]!r}")
    elif c == "defaults":
        status, body = get("/config")
        cfg = json.loads(body) if status == 200 else {}
        got = {k: cfg.get(k) for k in ("safe_search", "autocomplete", "default_locale", "public_instance")}
        ok = got["safe_search"] == 0 and not got["autocomplete"] and not got["default_locale"] and not got["public_instance"]
        status_p, prefs = get("/preferences")
        theme_auto = re.search(r'name="simple_style".*?value="auto"[^>]*selected', prefs, re.S) is not None
        check("defaults: safe search off, no autocomplete, language from browser, theme follows device, private",
              ok and theme_auto, f"{got}, theme auto selected: {theme_auto}")
    else:
        check(f"unknown check {c}", False)

sys.exit(FAILS)
