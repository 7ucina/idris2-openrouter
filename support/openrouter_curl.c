// A pull-based HTTP client over libcurl, for the Idris 2 OpenRouter bindings.
//
// A request belongs to one thread at a time; different requests may run on
// different threads at once. The calls that wait on the network (or_start,
// or_wait, or_save_run) take no strings and are bound from Idris as collect-safe, so a thread
// waiting in one does not hold up the garbage collector for the others.
//
// Idris asks for the next piece of the response body with or_next, so no C
// callback ever re-enters Idris, and a streamed response can be read as it
// arrives. Strings handed to Idris are owned by the request and stay valid
// until the next call on it. Body pieces always end on a UTF-8 character
// boundary, so a multi-byte character split across network reads is never
// decoded in halves.

#include <curl/curl.h>
#include <pthread.h>
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
  FILE              *file;     // where or_save_run writes
  curl_mime         *form;     // a multipart body under construction
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

static void global_init(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }

or_req *or_new(const char *method, const char *url) {
  static pthread_once_t once = PTHREAD_ONCE_INIT;
  pthread_once(&once, global_init);  // requests may start on several threads at once
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

// A multipart/form-data body, built one part at a time: a text field, or a
// file read from disk when the request is sent. filename and type may be ""
// to let libcurl choose (the file's own name; a type guessed from it).
void or_form_field(or_req *r, const char *name, const char *value) {
  if (!r->form) r->form = curl_mime_init(r->easy);
  if (!r->form) return;
  curl_mimepart *part = curl_mime_addpart(r->form);
  if (!part) return;
  curl_mime_name(part, name);
  curl_mime_data(part, value, CURL_ZERO_TERMINATED);
}

void or_form_file(or_req *r, const char *name, const char *path, const char *filename,
                  const char *type) {
  if (!r->form) r->form = curl_mime_init(r->easy);
  if (!r->form) return;
  curl_mimepart *part = curl_mime_addpart(r->form);
  if (!part) return;
  curl_mime_name(part, name);
  curl_mime_filedata(part, path);
  if (filename[0]) curl_mime_filename(part, filename);
  if (type[0]) curl_mime_type(part, type);
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
  if (r->form) curl_easy_setopt(r->easy, CURLOPT_MIMEPOST, r->form);
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

// Wait until or_next can answer without waiting: a piece that ends on a
// character boundary has arrived, or the response is over.
void or_wait(or_req *r) {
  size_t have = 0;
  for (;;) {
    pump(r, have);
    if (r->done) return;
    if (r->in.len > partial_tail(r->in.p, r->in.len)) return;
    have = r->in.len;  // only part of a character so far
  }
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

// Writing the rest of the body to a file, bytes untouched, for responses
// that are not text. In two steps, so that the step that waits on the
// network takes no string: or_save_to names the file (0 when it cannot be
// opened), or_save_run fills it and returns the number of bytes written, or
// -1 when the file could not be written. The transfer's own failure is
// reported by or_error.
int or_save_to(or_req *r, const char *path) {
  if (r->file) fclose(r->file);
  r->file = fopen(path, "wb");
  return r->file != NULL;
}

long or_save_run(or_req *r) {
  if (!r->file) return -1;
  long total = 0;
  int  bad = 0;
  for (;;) {
    pump(r, 0);
    if (r->in.len) {
      if (fwrite(r->in.p, 1, r->in.len, r->file) != r->in.len) bad = 1;
      total += (long)r->in.len;
      r->in.len = 0;
      r->in.p[0] = 0;
    }
    if (r->done) break;
  }
  if (fclose(r->file) != 0) bad = 1;
  r->file = NULL;
  return bad ? -1 : total;
}

void or_free(or_req *r) {
  if (!r) return;
  if (r->added) curl_multi_remove_handle(r->multi, r->easy);
  curl_easy_cleanup(r->easy);
  curl_multi_cleanup(r->multi);
  if (r->form) curl_mime_free(r->form);  // only once the handle that used it is gone
  curl_slist_free_all(r->headers);
  if (r->file) fclose(r->file);
  free(r->body);
  free(r->in.p);
  free(r->out.p);
  free(r->rh.p);
  free(r->hv.p);
  free(r);
}

// ---- Base64 files: how binary data (images, audio) crosses into JSON.

static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static _Thread_local buf b64_out;  // the encoding last handed out, per thread

// The contents of a file, base64-encoded. NULL-safe for Idris: "" when the
// file could not be read (see or_file_ok). The string is valid until the
// next call.
const char *or_file_base64(const char *path) {
  b64_out.len = 0;
  if (b64_out.p) b64_out.p[0] = 0;
  FILE *f = fopen(path, "rb");
  if (!f) return "";
  unsigned char in[3 * 1024];
  char          out[4 * 1024];
  size_t        n;
  while ((n = fread(in, 1, sizeof in, f)) > 0) {
    size_t o = 0;
    for (size_t i = 0; i < n; i += 3) {
      unsigned v = (unsigned)in[i] << 16;
      if (i + 1 < n) v |= (unsigned)in[i + 1] << 8;
      if (i + 2 < n) v |= in[i + 2];
      out[o++] = b64[v >> 18];
      out[o++] = b64[(v >> 12) & 63];
      out[o++] = i + 1 < n ? b64[(v >> 6) & 63] : '=';
      out[o++] = i + 2 < n ? b64[v & 63] : '=';
    }
    if (!buf_add(&b64_out, out, o)) break;
  }
  int bad = ferror(f);
  fclose(f);
  if (bad) {
    b64_out.len = 0;
    if (b64_out.p) b64_out.p[0] = 0;
  }
  return b64_out.p ? b64_out.p : "";
}

// 1 when the file exists and can be read.
int or_file_ok(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  fclose(f);
  return 1;
}

static int b64_value(unsigned char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+' || c == '-') return 62;  // the URL-safe alphabet too
  if (c == '/' || c == '_') return 63;
  return -1;
}

// Decode base64 text into a file. Padding ends a group, so pieces that were
// encoded one by one and then joined decode correctly; whitespace is
// skipped. The number of bytes written, or -1 when the text is not base64
// or the file could not be written.
long or_base64_file(const char *path, const char *text) {
  FILE *f = fopen(path, "wb");
  if (!f) return -1;
  long     total = 0;
  unsigned acc = 0;
  int      have = 0, bad = 0;
  for (const unsigned char *p = (const unsigned char *)text; *p && !bad; p++) {
    if (*p == '=') {  // flush a short group
      if (have == 2) {
        fputc((int)((acc >> 4) & 0xFF), f);
        total += 1;
      } else if (have == 3) {
        fputc((int)((acc >> 10) & 0xFF), f);
        fputc((int)((acc >> 2) & 0xFF), f);
        total += 2;
      } else if (have == 1) {
        bad = 1;
      }
      acc = 0;
      have = 0;
      continue;
    }
    if (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t') continue;
    int v = b64_value(*p);
    if (v < 0) {
      bad = 1;
      break;
    }
    acc = (acc << 6) | (unsigned)v;
    if (++have == 4) {
      fputc((int)((acc >> 16) & 0xFF), f);
      fputc((int)((acc >> 8) & 0xFF), f);
      fputc((int)(acc & 0xFF), f);
      total += 3;
      acc = 0;
      have = 0;
    }
  }
  if (have == 2) {  // unpadded tail
    fputc((int)((acc >> 4) & 0xFF), f);
    total += 1;
  } else if (have == 3) {
    fputc((int)((acc >> 10) & 0xFF), f);
    fputc((int)((acc >> 2) & 0xFF), f);
    total += 2;
  } else if (have == 1) {
    bad = 1;
  }
  if (ferror(f)) bad = 1;
  if (fclose(f) != 0) bad = 1;
  return bad ? -1 : total;
}

static void le(unsigned char *p, unsigned long v, int n) {
  for (int i = 0; i < n; i++) p[i] = (unsigned char)(v >> (8 * i));
}

// Copy headerless 16-bit little-endian PCM into a WAV file, which players
// and transcription models accept. The number of bytes written, or -1.
long or_pcm_to_wav(const char *pcm_path, const char *wav_path, int rate, int channels) {
  FILE *in = fopen(pcm_path, "rb");
  if (!in) return -1;
  if (fseek(in, 0, SEEK_END) != 0) {
    fclose(in);
    return -1;
  }
  long size = ftell(in);
  rewind(in);
  FILE *out = size < 0 ? NULL : fopen(wav_path, "wb");
  if (!out) {
    fclose(in);
    return -1;
  }
  unsigned char h[44];
  memcpy(h, "RIFF", 4);
  le(h + 4, (unsigned long)size + 36, 4);
  memcpy(h + 8, "WAVEfmt ", 8);
  le(h + 16, 16, 4);                                    // size of the format block
  le(h + 20, 1, 2);                                     // PCM
  le(h + 22, (unsigned long)channels, 2);
  le(h + 24, (unsigned long)rate, 4);
  le(h + 28, (unsigned long)rate * channels * 2, 4);    // bytes per second
  le(h + 32, (unsigned long)channels * 2, 2);           // bytes per frame
  le(h + 34, 16, 2);                                    // bits per sample
  memcpy(h + 36, "data", 4);
  le(h + 40, (unsigned long)size, 4);
  int    bad = fwrite(h, 1, sizeof h, out) != sizeof h;
  char   chunk[65536];
  size_t n;
  while (!bad && (n = fread(chunk, 1, sizeof chunk, in)) > 0)
    if (fwrite(chunk, 1, n, out) != n) bad = 1;
  if (ferror(in)) bad = 1;
  fclose(in);
  if (fclose(out) != 0) bad = 1;
  return bad ? -1 : size + 44;
}
