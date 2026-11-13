// A pull-based HTTP client over libcurl, for the Idris 2 OpenRouter bindings.
//
// Idris asks for the next piece of the response body with or_next, so no C
// callback ever re-enters Idris, and a streamed response can be read as it
// arrives. Strings handed to Idris are owned by the request and stay valid
// until the next call on it. Body pieces always end on a UTF-8 character
// boundary, so a multi-byte character split across network reads is never
// decoded in halves.

#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

typedef struct {
  char  *p;
  size_t len, cap;
} buf;

typedef struct or_req {
  CURL              *easy;
  CURLM             *multi;
  struct curl_slist *headers;
  char              *body;     // request body, kept alive for the transfer
  buf                in;       // response bytes received, not yet handed out
  buf                out;      // the piece last handed out
  buf                rh;       // response headers, "name: value\n" each
  buf                hv;       // the header value last handed out
  char               err[CURL_ERROR_SIZE];
  int                added, done;
  long               idle_ms;   // give up after this long with nothing received; 0: never
  long               last_ms;   // when something was last received
  CURLcode           code;
  CURLMcode          mcode;
} or_req;

static int buf_add(buf *b, const char *s, size_t n) {
  if (b->len + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < b->len + n + 1) cap *= 2;
    char *p = realloc(b->p, cap);
    if (!p) return 0;
    b->p = p;
    b->cap = cap;
  }
  memcpy(b->p + b->len, s, n);
  b->len += n;
  b->p[b->len] = 0;
  return 1;
}

static long now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static size_t on_body(char *ptr, size_t size, size_t n, void *ud) {
  or_req *r = ud;
  r->last_ms = now_ms();
  return buf_add(&r->in, ptr, size * n) ? size * n : 0;
}

static size_t on_header(char *ptr, size_t size, size_t n, void *ud) {
  or_req *r = ud;
  size_t  len = size * n;
  r->last_ms = now_ms();
  if (len >= 5 && !memcmp(ptr, "HTTP/", 5)) {
    r->rh.len = 0;  // a new response (after a redirect or a 100): start over
    if (r->rh.p) r->rh.p[0] = 0;
    return len;
  }
  size_t end = len;
  while (end > 0 && (ptr[end - 1] == '\r' || ptr[end - 1] == '\n')) end--;
  if (end == 0) return len;
  return buf_add(&r->rh, ptr, end) && buf_add(&r->rh, "\n", 1) ? len : 0;
}

or_req *or_new(const char *method, const char *url) {
  static int ready = 0;
  if (!ready) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    ready = 1;
  }
  or_req *r = calloc(1, sizeof *r);
  if (!r) return NULL;
  r->easy = curl_easy_init();
  r->multi = curl_multi_init();
  if (!r->easy || !r->multi) {
    if (r->easy) curl_easy_cleanup(r->easy);
    if (r->multi) curl_multi_cleanup(r->multi);
    free(r);
    return NULL;
  }
  curl_easy_setopt(r->easy, CURLOPT_URL, url);
  curl_easy_setopt(r->easy, CURLOPT_CUSTOMREQUEST, method);
  curl_easy_setopt(r->easy, CURLOPT_WRITEFUNCTION, on_body);
  curl_easy_setopt(r->easy, CURLOPT_WRITEDATA, r);
  curl_easy_setopt(r->easy, CURLOPT_HEADERFUNCTION, on_header);
  curl_easy_setopt(r->easy, CURLOPT_HEADERDATA, r);
  curl_easy_setopt(r->easy, CURLOPT_ERRORBUFFER, r->err);
  curl_easy_setopt(r->easy, CURLOPT_ACCEPT_ENCODING, "");  // whatever libcurl can decode
  curl_easy_setopt(r->easy, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(r->easy, CURLOPT_MAXREDIRS, 5L);
  curl_easy_setopt(r->easy, CURLOPT_NOSIGNAL, 1L);
  return r;
}

// One request header, as "Name: value".
void or_header(or_req *r, const char *line) {
  struct curl_slist *l = curl_slist_append(r->headers, line);
  if (l) r->headers = l;
}

void or_body(or_req *r, const char *body) {
  free(r->body);
  r->body = strdup(body);
  if (!r->body) return;
  curl_easy_setopt(r->easy, CURLOPT_POSTFIELDS, r->body);
  curl_easy_setopt(r->easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)strlen(r->body));
}

// connect_ms: time allowed to connect. total_ms: time allowed for the whole
// request. idle_ms: give up when nothing arrives for this long. 0 turns one off.
void or_timeouts(or_req *r, int connect_ms, int total_ms, int idle_ms) {
  curl_easy_setopt(r->easy, CURLOPT_CONNECTTIMEOUT_MS, (long)connect_ms);
  curl_easy_setopt(r->easy, CURLOPT_TIMEOUT_MS, (long)total_ms);
  r->idle_ms = idle_ms;
}

// Run the transfer until more than `have` bytes of the body are waiting, or
// it is over.
static void pump(or_req *r, size_t have) {
  while (!r->done && r->in.len <= have) {
    int running = 0;
    r->mcode = curl_multi_perform(r->multi, &running);
    if (r->mcode != CURLM_OK) {
      r->done = 1;
      break;
    }
    int      left;
    CURLMsg *m;
    while ((m = curl_multi_info_read(r->multi, &left)))
      if (m->msg == CURLMSG_DONE) {
        r->code = m->data.result;
        r->done = 1;
      }
    if (r->done || r->in.len > have) break;
    if (!running) {
      r->done = 1;
      break;
    }
    int wait = 1000;
    if (r->idle_ms > 0) {
      long left_ms = r->last_ms + r->idle_ms - now_ms();
      if (left_ms <= 0) {
        snprintf(r->err, sizeof r->err, "nothing received for %ld ms", r->idle_ms);
        r->code = CURLE_OPERATION_TIMEDOUT;
        r->done = 1;
        break;
      }
      if (left_ms < wait) wait = (int)left_ms;
    }
    r->mcode = curl_multi_poll(r->multi, NULL, 0, wait, NULL);
    if (r->mcode != CURLM_OK) r->done = 1;
  }
}

// Send the request and wait for the response to begin. 0 when it failed.
int or_start(or_req *r) {
  or_header(r, "Expect:");  // never wait for a 100 Continue before sending the body
  if (r->headers) curl_easy_setopt(r->easy, CURLOPT_HTTPHEADER, r->headers);
  r->mcode = curl_multi_add_handle(r->multi, r->easy);
  if (r->mcode != CURLM_OK) {
    r->done = 1;
    return 0;
  }
  r->added = 1;
  r->last_ms = now_ms();
  pump(r, 0);
  return !(r->done && (r->code != CURLE_OK || r->mcode != CURLM_OK));
}

int or_status(or_req *r) {
  long status = 0;
  curl_easy_getinfo(r->easy, CURLINFO_RESPONSE_CODE, &status);
  return (int)status;
}

// How many bytes at the end of p[0..n) are the start of a character whose
// remaining bytes have not arrived.
static size_t partial_tail(const char *p, size_t n) {
  size_t back = 0;
  while (back < n && back < 4) {
    unsigned char c = (unsigned char)p[n - 1 - back];
    back++;
    if ((c & 0xC0) == 0x80) continue;  // a continuation byte: keep looking for the lead
    size_t need = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
    return need > back ? back : 0;
  }
  return 0;
}

// The next piece of the body. "" once the response is over (see or_done).
const char *or_next(or_req *r) {
  r->out.len = 0;
  if (r->out.p) r->out.p[0] = 0;
  size_t have = 0;
  for (;;) {
    pump(r, have);
    size_t hold = r->done ? 0 : partial_tail(r->in.p, r->in.len);
    size_t take = r->in.len - hold;
    if (take == 0 && !r->done) {  // only part of a character so far: wait for the rest
      have = r->in.len;
      continue;
    }
    if (take) {
      for (size_t i = 0; i < take; i++)
        if (!r->in.p[i]) r->in.p[i] = ' ';  // a NUL would cut the string short
      buf_add(&r->out, r->in.p, take);
      memmove(r->in.p, r->in.p + take, hold);
      r->in.len = hold;
      r->in.p[hold] = 0;
    }
    return r->out.p ? r->out.p : "";
  }
}

// 1 when the response is over and all of it has been handed out.
int or_done(or_req *r) { return r->done && r->in.len == 0; }

// Why the transfer failed, or "" when it has not.
const char *or_error(or_req *r) {
  if (r->mcode != CURLM_OK) return curl_multi_strerror(r->mcode);
  if (r->code == CURLE_OK) return "";
  return r->err[0] ? r->err : curl_easy_strerror(r->code);
}

// 1 when the failure was a timeout.
int or_timed_out(or_req *r) { return r->code == CURLE_OPERATION_TIMEDOUT; }

// The value of a response header, or "" when the response has none by that name.
const char *or_response_header(or_req *r, const char *name) {
  size_t      n = strlen(name);
  const char *p = r->rh.p;
  r->hv.len = 0;
  if (r->hv.p) r->hv.p[0] = 0;
  while (p && *p) {
    const char *end = strchr(p, '\n');
    if (!end) end = p + strlen(p);
    if ((size_t)(end - p) > n && p[n] == ':' && !strncasecmp(p, name, n)) {
      const char *v = p + n + 1;
      while (v < end && (*v == ' ' || *v == '\t')) v++;
      buf_add(&r->hv, v, (size_t)(end - v));
      break;
    }
    p = *end ? end + 1 : end;
  }
  return r->hv.p ? r->hv.p : "";
}

void or_free(or_req *r) {
  if (!r) return;
  if (r->added) curl_multi_remove_handle(r->multi, r->easy);
  curl_easy_cleanup(r->easy);
  curl_multi_cleanup(r->multi);
  curl_slist_free_all(r->headers);
  free(r->body);
  free(r->in.p);
  free(r->out.p);
  free(r->rh.p);
  free(r->hv.p);
  free(r);
}
