import Foundation

/// Single-pass JavaScript annotation engine injected into `WKWebView` (and testable via `JavaScriptCore`).
/// Handles full-spine text indexing, W3C `quotePrefix`/`quoteSuffix` self-healing anchoring
/// (for both ranged highlights and 0-length point bookmarks), non-destructive text edits,
/// and longest-first `data-overlap="underline"` `<mark>` wrapping in one batched call.
enum AnnotationEngineJS {

    // swiftlint:disable function_body_length
    static let script: String = #"""
    (function() {
        if (window.__ambrosiaAnnotationEngineInstalled) return;
        window.__ambrosiaAnnotationEngineInstalled = true;

        var SIMILARITY_FLOOR = 0.35;

        function isIgnoredNode(node) {
            var cur = node.parentNode;
            while (cur && cur !== document.body) {
                if (cur.nodeType === 1) {
                    var tag = cur.tagName;
                    if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') return true;
                    if (cur.hasAttribute && cur.hasAttribute('data-ambrosia-ornament')) return true;
                }
                cur = cur.parentNode;
            }
            return false;
        }

        function buildTextIndex(root) {
            var target = root || document.body;
            var walker = document.createTreeWalker(target, NodeFilter.SHOW_TEXT, null);
            var nodes = [];
            var offsets = [];
            var parts = [];
            var cum = 0;
            var node;
            while ((node = walker.nextNode()) !== null) {
                if (isIgnoredNode(node)) continue;
                nodes.push(node);
                offsets.push(cum);
                parts.push(node.nodeValue || '');
                cum += node.length;
            }
            return {
                nodes: nodes,
                offsets: offsets,
                fullText: parts.join(''),
                length: cum
            };
        }

        function extractContext(fullText, startChar, endChar) {
            var prefixStart = Math.max(0, startChar - 200);
            var suffixEnd = Math.min(fullText.length, endChar + 200);
            return {
                quotePrefix: fullText.slice(prefixStart, startChar),
                quoteSuffix: fullText.slice(endChar, suffixEnd)
            };
        }

        function findNearestChapterTitle(node) {
            if (!node || typeof document === 'undefined') return null;
            var target = node.nodeType === 3 ? node.parentElement : node;
            var headings = Array.from(document.querySelectorAll('h1, h2, h3, h4'));
            var best = null;
            for (var i = 0; i < headings.length; i++) {
                var h = headings[i];
                if (h === target || (h.compareDocumentPosition(target) & Node.DOCUMENT_POSITION_FOLLOWING)) {
                    var txt = (h.textContent || '').trim();
                    if (txt.length > 0) best = txt;
                }
            }
            return best;
        }

        function suffixSimilarity(expected, actual) {
            if (!expected && !actual) return 1;
            if (!expected || !actual) return 0;
            var len = Math.min(expected.length, actual.length, 200);
            var matches = 0;
            for (var i = 1; i <= len; i++) {
                if (expected.charCodeAt(expected.length - i) === actual.charCodeAt(actual.length - i)) {
                    matches++;
                } else {
                    break;
                }
            }
            return matches / Math.max(1, Math.min(expected.length, 40));
        }

        function prefixSimilarity(expected, actual) {
            if (!expected && !actual) return 1;
            if (!expected || !actual) return 0;
            var len = Math.min(expected.length, actual.length, 200);
            var matches = 0;
            for (var i = 0; i < len; i++) {
                if (expected.charCodeAt(i) === actual.charCodeAt(i)) {
                    matches++;
                } else {
                    break;
                }
            }
            return matches / Math.max(1, Math.min(expected.length, 40));
        }

        function scoreContext(fullText, start, end, quotePrefix, quoteSuffix) {
            var ctx = extractContext(fullText, start, end);
            var hasPrefix = !!(quotePrefix && quotePrefix.length > 0);
            var hasSuffix = !!(quoteSuffix && quoteSuffix.length > 0);
            if (!hasPrefix && !hasSuffix) return 0.5;
            var pScore = hasPrefix ? suffixSimilarity(quotePrefix, ctx.quotePrefix) : 0;
            var sScore = hasSuffix ? prefixSimilarity(quoteSuffix, ctx.quoteSuffix) : 0;
            if (hasPrefix && hasSuffix) return (pScore + sScore) / 2;
            return hasPrefix ? pScore : sScore;
        }

        function findAllOccurrences(haystack, needle) {
            var results = [];
            if (!needle || needle.length === 0) return results;
            var idx = 0;
            while ((idx = haystack.indexOf(needle, idx)) !== -1) {
                results.push(idx);
                idx += 1;
            }
            return results;
        }

        function normalizeWhitespaceMap(text) {
            var norm = '';
            var map = [];
            var inSpace = false;
            for (var i = 0; i < text.length; i++) {
                var ch = text[i];
                if (/\s/.test(ch)) {
                    if (!inSpace && norm.length > 0) {
                        norm += ' ';
                        map.push(i);
                        inSpace = true;
                    }
                } else {
                    norm += ch;
                    map.push(i);
                    inSpace = false;
                }
            }
            return { norm: norm, map: map };
        }

        function resolvePointAnchor(fullText, item) {
            var start = item.startChar || 0;
            var prefix = item.quotePrefix || '';
            var suffix = item.quoteSuffix || '';

            if (!item.needsReanchor && start >= 0 && start <= fullText.length) {
                if (!prefix && !suffix) {
                    return { matched: true, startChar: start, endChar: start, moved: false };
                }
                var localScore = scoreContext(fullText, start, start, prefix, suffix);
                if (localScore >= 0.75) {
                    return { matched: true, startChar: start, endChar: start, moved: false };
                }
            }

            if (prefix && suffix) {
                var pTail = prefix.slice(-32);
                var sHead = suffix.slice(0, 32);
                var combined = pTail + sHead;
                var hits = findAllOccurrences(fullText, combined);
                if (hits.length > 0) {
                    var bestHit = hits[0] + pTail.length;
                    var bestScore = -1;
                    for (var i = 0; i < hits.length; i++) {
                        var candidate = hits[i] + pTail.length;
                        var sc = scoreContext(fullText, candidate, candidate, prefix, suffix);
                        if (sc > bestScore) {
                            bestScore = sc;
                            bestHit = candidate;
                        }
                    }
                    return {
                        matched: true,
                        startChar: bestHit,
                        endChar: bestHit,
                        moved: bestHit !== start
                    };
                }
            }

            if (prefix && prefix.length >= 12) {
                var pHits = findAllOccurrences(fullText, prefix.slice(-24));
                if (pHits.length > 0) {
                    var pos = pHits[0] + Math.min(24, prefix.length);
                    return { matched: true, startChar: pos, endChar: pos, moved: pos !== start };
                }
            }

            if (suffix && suffix.length >= 12) {
                var sHits = findAllOccurrences(fullText, suffix.slice(0, 24));
                if (sHits.length > 0) {
                    var pos2 = sHits[0];
                    return { matched: true, startChar: pos2, endChar: pos2, moved: pos2 !== start };
                }
            }

            return { matched: false };
        }

        function resolveAnnotationAnchor(fullText, item) {
            if (item.startChar === item.endChar) {
                return resolvePointAnchor(fullText, item);
            }

            var targetText = item.originalText || item.selectedText || '';
            if (!targetText) return { matched: false };

            var start = item.startChar;
            var end = item.endChar;
            if (!item.needsReanchor && start >= 0 && end <= fullText.length) {
                if (fullText.slice(start, end) === targetText) {
                    return { matched: true, startChar: start, endChar: end, moved: false };
                }
            }

            var occurrences = findAllOccurrences(fullText, targetText);
            if (occurrences.length > 0) {
                var bestIdx = -1;
                var bestScore = -1;
                for (var i = 0; i < occurrences.length; i++) {
                    var cand = occurrences[i];
                    var sc = scoreContext(fullText, cand, cand + targetText.length, item.quotePrefix, item.quoteSuffix);
                    if (sc > bestScore) {
                        bestScore = sc;
                        bestIdx = cand;
                    }
                }
                if (bestIdx !== -1 && (occurrences.length === 1 || bestScore >= SIMILARITY_FLOOR)) {
                    return {
                        matched: true,
                        startChar: bestIdx,
                        endChar: bestIdx + targetText.length,
                        moved: bestIdx !== start || (bestIdx + targetText.length) !== end
                    };
                }
            }

            // Whitespace-normalized fallback
            var normTarget = targetText.replace(/\s+/g, ' ').trim();
            if (normTarget.length >= 4) {
                var mapped = normalizeWhitespaceMap(fullText);
                var normIdx = mapped.norm.indexOf(normTarget);
                if (normIdx !== -1 && normIdx + normTarget.length - 1 < mapped.map.length) {
                    var rawStart = mapped.map[normIdx];
                    var rawEnd = mapped.map[normIdx + normTarget.length - 1] + 1;
                    return {
                        matched: true,
                        startChar: rawStart,
                        endChar: rawEnd,
                        moved: rawStart !== start || rawEnd !== end
                    };
                }
            }

            return { matched: false };
        }

        function applyTextEditInIndex(index, startChar, endChar, replacementText) {
            var segments = [];
            for (var i = 0; i < index.nodes.length; i++) {
                var nStart = index.offsets[i];
                var nEnd = nStart + index.nodes[i].length;
                if (nEnd <= startChar) continue;
                if (nStart >= endChar) break;
                segments.push({
                    node: index.nodes[i],
                    from: Math.max(0, startChar - nStart),
                    to: Math.min(index.nodes[i].length, endChar - nStart)
                });
            }
            if (segments.length === 0) return false;
            var first = segments[0];
            var val = first.node.nodeValue || '';
            first.node.nodeValue = val.slice(0, first.from) + replacementText + val.slice(first.to);
            for (var s = 1; s < segments.length; s++) {
                var seg = segments[s];
                var segVal = seg.node.nodeValue || '';
                seg.node.nodeValue = segVal.slice(0, seg.from) + segVal.slice(seg.to);
            }
            return true;
        }

        function wrapRange(index, startChar, endChar, item, useUnderline) {
            var segments = [];
            for (var i = 0; i < index.nodes.length; i++) {
                var nStart = index.offsets[i];
                var nEnd = nStart + index.nodes[i].length;
                if (nEnd <= startChar) continue;
                if (nStart >= endChar) break;
                segments.push({
                    node: index.nodes[i],
                    from: Math.max(0, startChar - nStart),
                    to: Math.min(index.nodes[i].length, endChar - nStart)
                });
            }
            if (segments.length === 0) return;

            var hid = (item.id || '').replace(/-/g, '');
            if (document.getElementById('hl-' + hid + '-0') || document.getElementById('hl-' + hid)) return;

            for (var si = 0; si < segments.length; si++) {
                var seg = segments[si];
                var txtNode = seg.node;
                var parent = txtNode.parentNode;
                if (!parent) continue;

                var before = seg.from > 0 ? txtNode.splitText(seg.from) : txtNode;
                if ((seg.to - seg.from) < before.length) {
                    before.splitText(seg.to - seg.from);
                }

                var el = document.createElement(item.hasHighlight === false ? 'span' : 'mark');
                el.id = 'hl-' + hid + (segments.length === 1 ? '' : '-' + si);
                el.className = item.hasHighlight === false ? 'ambrosia-edit-only' : 'ambrosia-highlight';
                el.setAttribute('data-ambrosia-highlight', '1');
                el.setAttribute('data-hl-base', hid);
                if (item.hasHighlight !== false) {
                    el.setAttribute('data-annotation-color', item.colorKey || 'yellow');
                    if (useUnderline) el.setAttribute('data-overlap', 'underline');
                }
                el.addEventListener('click', (function(baseHid) {
                    return function(e) {
                        e.stopPropagation();
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.highlightTapped) {
                            window.webkit.messageHandlers.highlightTapped.postMessage(JSON.stringify({
                                id: baseHid,
                                x: e.clientX,
                                y: e.clientY
                            }));
                        }
                    };
                })(hid));

                parent.insertBefore(el, before);
                el.appendChild(before);
            }
        }

        function renderBatchEncoded(payloadBase64) {
            var jsonStr = decodeURIComponent(escape(atob(payloadBase64)));
            var payload = JSON.parse(jsonStr);
            var items = payload.annotations || [];
            var pageStart = window._ambrosiaPageStart || 0;
            var pageEnd = window._ambrosiaPageEnd || Number.MAX_SAFE_INTEGER;

            var index = buildTextIndex(document.body);
            var reanchored = [];
            var orphanedIDs = [];
            var resolved = [];

            for (var i = 0; i < items.length; i++) {
                var item = items[i];
                var res = resolveAnnotationAnchor(index.fullText, item);
                if (!res.matched) {
                    orphanedIDs.push(item.id);
                    continue;
                }
                if (res.moved || item.needsReanchor) {
                    var ctx = extractContext(index.fullText, res.startChar, res.endChar);
                    reanchored.push({
                        id: item.id,
                        startChar: res.startChar,
                        endChar: res.endChar,
                        quotePrefix: ctx.quotePrefix,
                        quoteSuffix: ctx.quoteSuffix
                    });
                }
                resolved.push({
                    item: item,
                    startChar: res.startChar,
                    endChar: res.endChar
                });
            }

            // Apply non-destructive text edits in descending offset order before wrapping marks.
            var edits = resolved.filter(function(r) {
                return r.item.originalText !== null && r.item.originalText !== undefined &&
                       r.item.replacementText !== null && r.item.replacementText !== undefined;
            }).sort(function(a, b) { return b.startChar - a.startChar; });

            if (edits.length > 0) {
                for (var e = 0; e < edits.length; e++) {
                    var ed = edits[e];
                    var localStart = ed.startChar - pageStart;
                    var localEnd = ed.endChar - pageStart;
                    if (localStart >= 0 && localEnd <= index.length) {
                        var delta = ed.item.replacementText.length - (ed.endChar - ed.startChar);
                        applyTextEditInIndex(index, localStart, localEnd, ed.item.replacementText);
                        ed.endChar = ed.startChar + ed.item.replacementText.length;
                        for (var r = 0; r < resolved.length; r++) {
                            if (resolved[r].startChar > ed.startChar) {
                                resolved[r].startChar += delta;
                                resolved[r].endChar += delta;
                            }
                        }
                        if (pageEnd < Number.MAX_SAFE_INTEGER) {
                            pageEnd += delta;
                            window._ambrosiaPageEnd = pageEnd;
                        }
                        index = buildTextIndex(document.body);
                    }
                }
            }

            // Filter to ranged/edited items visible in the current page slice and sort longest-first.
            var renderables = resolved.filter(function(r) {
                return r.endChar > r.startChar && r.endChar > pageStart && r.startChar < pageEnd;
            }).sort(function(a, b) {
                return (b.endChar - b.startChar) - (a.endChar - a.startChar);
            });

            var renderedRanges = [];
            for (var k = 0; k < renderables.length; k++) {
                var cur = renderables[k];
                var s = Math.max(cur.startChar, pageStart) - pageStart;
                var en = Math.min(cur.endChar, pageEnd) - pageStart;
                if (en <= s) continue;

                var overlaps = false;
                for (var rr = 0; rr < renderedRanges.length; rr++) {
                    if (s < renderedRanges[rr].end && en > renderedRanges[rr].start) {
                        overlaps = true;
                        break;
                    }
                }
                renderedRanges.push({ start: s, end: en });
                // Rebuild index only if previous mark split text nodes cleanly; offsets remain valid per wrapRange.
                var freshIndex = buildTextIndex(document.body);
                wrapRange(freshIndex, s, en, cur.item, overlaps);
            }

            return JSON.stringify({ reanchored: reanchored, orphanedIDs: orphanedIDs });
        }

        window.ambrosiaAnnotationEngine = {
            buildTextIndex: buildTextIndex,
            extractContext: extractContext,
            findNearestChapterTitle: findNearestChapterTitle,
            resolveAnnotationAnchor: resolveAnnotationAnchor,
            renderBatchEncoded: renderBatchEncoded
        };
    })();
    """#
    // swiftlint:enable function_body_length
}
