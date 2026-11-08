import Foundation

/// One fake edit: existing code, the lines being replaced, the lines being typed, and the code after them.
struct FileEdit {
    let path: String
    let context: [String]
    let removed: [String]
    let added: [String]
    let after: [String]
    let symbol: String
}

private struct Template {
    let context: String
    let removed: String
    let added: String
    let after: String
}

/// Templates use @P@ (PascalCase), @c@ (camelCase) and @s@ (snake_case), filled from the file name.
enum CodeGen {
    static func make(path: String, lang: Lang, rng: inout SplitMix64) -> FileEdit {
        let n = Names(path: path)
        let t = rng.pick(templates[lang] ?? templates[.typescript]!)
        func fill(_ raw: String) -> [String] {
            var s = raw
            for suffix in ["Schema", "Service", "Store", "Client", "Worker", "Cache", "Block", "Config"] where n.pascal.hasSuffix(suffix) {
                s = s.replacingOccurrences(of: "@P@" + suffix, with: "@P@")
            }
            return s.replacingOccurrences(of: "@P@", with: n.pascal)
                .replacingOccurrences(of: "@c@", with: n.camel)
                .replacingOccurrences(of: "@s@", with: n.snake)
                .components(separatedBy: "\n")
        }
        return FileEdit(path: path, context: fill(t.context), removed: fill(t.removed),
                        added: fill(t.added), after: fill(t.after), symbol: n.camel)
    }

    private static let templates: [Lang: [Template]] = [
        .typescript: [
            Template(context: #"""
import { logger } from '../lib/logger';
import { retry } from '../lib/retry';
import type { @P@Options, @P@Result } from './types';

const DEFAULT_TIMEOUT_MS = 8_000;

export class @P@Service {
  constructor(private readonly opts: @P@Options) {}

"""#, removed: #"""
  async run(input: string): Promise<@P@Result> {
    const res = await fetch(this.opts.endpoint, { body: input });
    return res.json();
  }
"""#, added: #"""
  async run(input: string, signal?: AbortSignal): Promise<@P@Result> {
    return retry(async (attempt) => {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), DEFAULT_TIMEOUT_MS);
      try {
        const res = await fetch(this.opts.endpoint, {
          method: 'POST',
          body: input,
          signal: signal ?? controller.signal,
        });
        if (!res.ok) throw new Error(`@c@ failed: ${res.status}`);
        return (await res.json()) as @P@Result;
      } finally {
        clearTimeout(timer);
        logger.debug({ attempt }, '@c@.run finished');
      }
    }, { retries: 3, backoffMs: 250 });
  }
"""#, after: #"""

  async health(): Promise<boolean> {
    try {
      await this.run('ping');
      return true;
    } catch {
      return false;
    }
  }
}
"""#),
            Template(context: #"""
import { z } from 'zod';
import { db } from '../db';
import { logger } from '../lib/logger';

export const @P@Schema = z.object({
  id: z.string().uuid(),
  email: z.string().email(),
  plan: z.enum(['free', 'pro', 'team']),
});

"""#, removed: #"""
export async function update@P@(input: unknown) {
  const data = @P@Schema.parse(input);
  return db.@c@.update({ where: { id: data.id }, data });
}
"""#, added: #"""
export async function update@P@(input: unknown, actorId: string) {
  const parsed = @P@Schema.safeParse(input);
  if (!parsed.success) {
    logger.warn({ issues: parsed.error.issues }, 'invalid @c@ payload');
    return { ok: false as const, error: 'VALIDATION_FAILED' };
  }
  const { id, ...data } = parsed.data;
  const updated = await db.$transaction(async (tx) => {
    const row = await tx.@c@.update({ where: { id }, data });
    await tx.auditLog.create({
      data: { actorId, action: '@c@.update', targetId: id },
    });
    return row;
  });
  return { ok: true as const, value: updated };
}
"""#, after: #"""

export type @P@ = z.infer<typeof @P@Schema>;
"""#),
        ],
        .python: [
            Template(context: #"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

import numpy as np

log = logging.getLogger(__name__)


@dataclass
class @P@Config:
    root: Path
    batch_size: int = 64
    num_workers: int = 8
    cache: bool = True

"""#, removed: #"""
def load_@s@(cfg: @P@Config):
    files = sorted(cfg.root.glob("*.npy"))
    return [np.load(f) for f in files]
"""#, added: #"""
def load_@s@(cfg: @P@Config, *, limit: int | None = None) -> list[np.ndarray]:
    files = sorted(cfg.root.glob("*.npy"))[:limit]
    if not files:
        raise FileNotFoundError(f"no .npy files under {cfg.root}")
    out: list[np.ndarray] = []
    for i, f in enumerate(files):
        arr = np.load(f, mmap_mode="r" if cfg.cache else None)
        if arr.ndim != 3:
            log.warning("skipping %s: expected 3 dims, got %d", f.name, arr.ndim)
            continue
        out.append(np.asarray(arr, dtype=np.float32))
        if i % 100 == 0:
            log.info("loaded %d/%d", i + 1, len(files))
    return out
"""#, after: #"""


def summarize(arrays: list[np.ndarray]) -> dict[str, float]:
    stacked = np.concatenate([a.reshape(-1) for a in arrays])
    return {"mean": float(stacked.mean()), "std": float(stacked.std())}
"""#),
            Template(context: #"""
import torch
from torch import nn
import torch.nn.functional as F


class @P@Block(nn.Module):
    def __init__(self, dim: int, hidden: int, dropout: float = 0.1) -> None:
        super().__init__()
        self.norm = nn.LayerNorm(dim)
        self.fc1 = nn.Linear(dim, hidden)
        self.fc2 = nn.Linear(hidden, dim)
        self.drop = nn.Dropout(dropout)

"""#, removed: #"""
    def forward(self, x):
        return x + self.fc2(F.relu(self.fc1(self.norm(x))))
"""#, added: #"""
    def forward(self, x: torch.Tensor, mask: torch.Tensor | None = None) -> torch.Tensor:
        h = self.norm(x)
        h = F.gelu(self.fc1(h))
        h = self.drop(h)
        h = self.fc2(h)
        if mask is not None:
            h = h.masked_fill(~mask.unsqueeze(-1), 0.0)
        return x + self.drop(h)
"""#, after: #"""


def build_@s@(depth: int = 6, dim: int = 512) -> nn.Sequential:
    return nn.Sequential(*[@P@Block(dim, dim * 4) for _ in range(depth)])
"""#),
        ],
        .swift: [
            Template(context: #"""
import Foundation
import OSLog

private let log = Logger(subsystem: "app", category: "@P@")

actor @P@Store {
    private var cache: [String: Entry] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 300) {
        self.ttl = ttl
    }

"""#, removed: #"""
    func value(for key: String) -> Data? {
        cache[key]?.data
    }
"""#, added: #"""
    func value(for key: String, now: Date = .now) -> Data? {
        guard let entry = cache[key] else {
            log.debug("miss \(key, privacy: .public)")
            return nil
        }
        if now.timeIntervalSince(entry.storedAt) > ttl {
            cache[key] = nil
            log.debug("expired \(key, privacy: .public)")
            return nil
        }
        return entry.data
    }

    func insert(_ data: Data, for key: String, now: Date = .now) {
        cache[key] = Entry(data: data, storedAt: now)
    }
"""#, after: #"""
}

private struct Entry {
    let data: Data
    let storedAt: Date
}
"""#),
            Template(context: #"""
import Foundation

struct @P@Client {
    let session: URLSession
    let baseURL: URL

"""#, removed: #"""
    func fetch(_ path: String) async throws -> Data {
        let (data, _) = try await session.data(from: baseURL.appending(path: path))
        return data
    }
"""#, added: #"""
    func fetch(_ path: String, retries: Int = 3) async throws -> Data {
        var lastError: Error?
        for attempt in 0...retries {
            do {
                let (data, response) = try await session.data(from: baseURL.appending(path: path))
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(200 << attempt))
            }
        }
        throw lastError ?? URLError(.unknown)
    }
"""#, after: #"""

    func decode<T: Decodable>(_ type: T.Type, from path: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await fetch(path))
    }
}
"""#),
        ],
        .go: [
            Template(context: #"""
package worker

import (
    "context"
    "errors"
    "fmt"
    "time"
)

type @P@Worker struct {
    queue   <-chan Job
    timeout time.Duration
}

"""#, removed: #"""
func (w *@P@Worker) Run(ctx context.Context) {
    for job := range w.queue {
        w.handle(job)
    }
}
"""#, added: #"""
func (w *@P@Worker) Run(ctx context.Context) error {
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case job, ok := <-w.queue:
            if !ok {
                return nil
            }
            jctx, cancel := context.WithTimeout(ctx, w.timeout)
            err := w.handle(jctx, job)
            cancel()
            if errors.Is(err, context.DeadlineExceeded) {
                return fmt.Errorf("@c@: job %s timed out: %w", job.ID, err)
            }
        }
    }
}
"""#, after: #"""

func (w *@P@Worker) handle(ctx context.Context, job Job) error {
    return job.Do(ctx)
}
"""#),
        ],
        .cpp: [
            Template(context: #"""
#include <algorithm>
#include <stdexcept>
#include <vector>

#include "@s@.h"

namespace @s@ {

"""#, removed: #"""
std::vector<float> @c@(const std::vector<float>& in, int n) {
    std::vector<float> out(n);
    for (int i = 0; i < n; ++i) out[i] = in[i] * in[i];
    return out;
}
"""#, added: #"""
std::vector<float> @c@(const std::vector<float>& in, int n, float gain) {
    if (static_cast<int>(in.size()) < n) {
        throw std::invalid_argument("@c@: input shorter than n");
    }
    std::vector<float> out(n);
    float peak = 0.0f;
    for (int i = 0; i < n; ++i) {
        const float v = in[i] * gain;
        out[i] = v * v;
        peak = std::max(peak, out[i]);
    }
    if (peak > 0.0f) {
        for (auto& v : out) v /= peak;
    }
    return out;
}
"""#, after: #"""

}  // namespace @s@
"""#),
            Template(context: #"""
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>

class @P@Cache {
public:
    explicit @P@Cache(std::size_t capacity) : capacity_(capacity) {}

"""#, removed: #"""
    std::optional<std::string> get(const std::string& key) {
        return map_[key];
    }
"""#, added: #"""
    std::optional<std::string> get(const std::string& key) {
        std::lock_guard<std::mutex> lock(mu_);
        auto it = map_.find(key);
        if (it == map_.end()) {
            ++misses_;
            return std::nullopt;
        }
        ++hits_;
        return it->second;
    }

    void put(const std::string& key, std::string value) {
        std::lock_guard<std::mutex> lock(mu_);
        if (map_.size() >= capacity_) map_.erase(map_.begin());
        map_[key] = std::move(value);
    }
"""#, after: #"""

private:
    std::size_t capacity_;
    std::unordered_map<std::string, std::string> map_;
    std::mutex mu_;
    std::size_t hits_ = 0, misses_ = 0;
};
"""#),
        ],
    ]
}
