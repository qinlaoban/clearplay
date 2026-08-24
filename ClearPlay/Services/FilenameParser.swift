import Foundation

/// 文件名解析器：从 "Movie.Name.2023.1080p.BluRay.x264.mkv" 这类文件名中
/// 提取标题、年份、剧集 S/E 信息
enum FilenameParser {
    struct Result {
        var title: String
        var year: Int?
        var kind: MediaKind = .movie
        var seriesName: String?
        var season: Int?
        var episodeNumber: Int?
    }

    /// 视频文件扩展名白名单
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "ts", "webm", "mpg", "mpeg"
    ]

    // 剧集标记：S01E02 / 1x02 / Season 1 Episode 2
    private static let sePatterns: [(NSRegularExpression, isSeasonExplicit: Bool)] = {
        let sources = [
            #"[Ss](\d{1,2})\s?[Ee](\d{1,3})"#,
            #"(\d{1,2})x(\d{1,3})"#,
            #"[Ss]eason\s*(\d{1,2}).*?[Ee]p?\s*(\d{1,3})"#,
        ]
        return sources.compactMap { pattern in
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (re, true)
        }
    }()

    // 质量/来源等噪音标记：标题在这些词前截断
    private static let noisePattern = try! NSRegularExpression(
        pattern: """
        (?ix)
        \\b(19\\d{2}|20\\d{2})\\b            # 年份
        |\\b(2160p|1080p|1080i|720p|480p|4k|uhd)\\b
        |\\b(blu-?ray|bdrip|brrip|web-?dl|webrip|web|hdtv|dvdrip|hdrip|remux)\\b
        |\\b(x26[45]|h\\.?26[45]|hevc|avc|xvid|divx)\\b
        |\\b(aac|ac3|eac3|ddp?|dts(-hd)?|truehd|atmos|flac|opus)\\b
        |\\b(hdr|dv|dolby.vision|10bit|8bit)\\b
        |\\b(chs?&eng|chs|cht|eng|mandarin|简体|繁體|中英双字)\\b
        """
    )

    private static let yearPattern = try! NSRegularExpression(pattern: #"\b(19\d{2}|20\d{2})\b"#)

    static func parse(_ filename: String) -> Result {
        // 去掉扩展名，统一分隔符为空格
        var name = (filename as NSString).deletingPathExtension
        name = name.replacingOccurrences(of: ".", with: " ")
                     .replacingOccurrences(of: "_", with: " ")
        name = name.collapseSpaces()

        // 1. 尝试剧集匹配
        for (re, _) in sePatterns {
            let range = NSRange(name.startIndex..., in: name)
            if let m = re.firstMatch(in: name, range: range),
               let sRange = Range(m.range(at: 1), in: name),
               let eRange = Range(m.range(at: 2), in: name),
               let season = Int(name[sRange]), let ep = Int(name[eRange]) {
                // 标题取整个 SxxExx 匹配之前的文本
                let matchStart = Range(m.range, in: name)?.lowerBound ?? sRange.lowerBound
                let rawTitle = String(name[..<matchStart])
                return Result(
                    title: cleanTitle(rawTitle) ?? cleanTitleLoose(name),
                    year: findYear(in: name),
                    kind: .episode,
                    seriesName: cleanTitle(rawTitle),
                    season: season,
                    episodeNumber: ep
                )
            }
        }

        // 2. 电影：标题在年份或第一个噪音词前截断
        let full = NSRange(name.startIndex..., in: name)
        var cutIndex = name.endIndex
        if let ym = yearPattern.firstMatch(in: name, range: full),
           let yr = Range(ym.range(at: 1), in: name), let year = Int(name[yr]),
           (1900...2100).contains(year) {
            cutIndex = yr.lowerBound
        }
        if let nm = noisePattern.firstMatch(in: name, range: full),
           let nr = Range(nm.range, in: name),
           nr.lowerBound < cutIndex {
            cutIndex = nr.lowerBound
        }
        let rawTitle = String(name[..<cutIndex])
        let title = cleanTitle(rawTitle) ?? cleanTitleLoose(name)
        return Result(title: title, year: findYear(in: name))
    }

    /// 清洗标题尾部残留的连接符与空白
    private static func cleanTitle(_ raw: String) -> String? {
        let cleaned = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—[]()"))
            .collapseSpaces()
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 兜底：整串去噪音词后作为标题（避免空标题）
    private static func cleanTitleLoose(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        var out = s
        noisePattern.enumerateMatches(in: s, range: range) { m, _, _ in
            guard let m, let r = Range(m.range, in: out) else { return }
            out.replaceSubrange(r, with: "\u{0}")
        }
        return out
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—[]()"))
            .collapseSpaces()
    }

    private static func findYear(in s: String) -> Int? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = yearPattern.firstMatch(in: s, range: range),
              let r = Range(m.range(at: 1), in: s),
              let y = Int(s[r]), (1900...2100).contains(y) else { return nil }
        return y
    }
}

private extension String {
    func collapseSpaces() -> String {
        self.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
    }
}
