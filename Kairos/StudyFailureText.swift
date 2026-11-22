import Foundation

/// Plain-language wording for a failed download. The raw tool or system text
/// stays available behind "Details…"; rows show only this.
struct StudyFailureText: Equatable {
    enum Action: Equatable { case retry, signIn, remove, downloadAgain, importAgain, none }

    let text: String
    let action: Action

    static func describe(_ raw: String, signInFilePresent: Bool) -> Self {
        let value = raw.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { value.contains($0) } }
        if has("sign-in file", "cookies.txt export") {
            return .init(text: "Your YouTube sign-in file can't be used. Replace it in Settings.", action: .signIn)
        }
        // Checked before anything mentioning cookies: yt-dlp ends private,
        // members-only and age errors with a "--cookies" hint, and those
        // videos never work by retrying.
        if has("no space left", "errno 28", "disk full", "not enough space", "out of space") {
            return .init(text: "Your Mac is out of space. Free some up, then try again.", action: .retry)
        }
        if has("private video") {
            return .init(text: "This video is private.", action: .remove)
        }
        if has("members-only", "members only", "join this channel") {
            return .init(text: "This video is for channel members only.", action: .remove)
        }
        if has("age-restricted", "confirm your age", "inappropriate for some users") {
            return signInFilePresent
                ? .init(text: "This video is age-restricted and can't be downloaded.", action: .remove)
                : .init(text: "This video is age-restricted. Add your YouTube sign-in in Settings, then try again.",
                        action: .signIn)
        }
        if has("video unavailable", "has been removed", "this video is unavailable", "no longer available") {
            return .init(text: "This video was removed or is no longer available.", action: .remove)
        }
        // YouTube's temporary refusals: worth another try later, not removal.
        if has("requested format is not available", "try again later") {
            return .init(text: "YouTube didn't offer this video just now. Try again later.", action: .retry)
        }
        // Every way Shield tries was refused for the file itself.
        if has("http error 403", "forbidden", "unable to download video data") {
            return .init(text: "YouTube refused this video just now. Try again later.", action: .retry)
        }
        if has("confirm you're not a bot", "confirm you’re not a bot", "sign in to confirm", "cookies") {
            return signInFilePresent
                ? .init(text: "YouTube paused this download. Try again later.", action: .retry)
                : .init(text: "YouTube wants a sign-in. Add it in Settings, then try again.", action: .signIn)
        }
        if has("not available") {
            return .init(text: "This video was removed or is no longer available.", action: .remove)
        }
        if has("required tool is unavailable", "tool is unavailable") {
            return .init(text: "Shield couldn't find its download tools. Try again; if it repeats, reopen Shield.",
                         action: .retry)
        }
        if has("stopped making progress") {
            return .init(text: "This download got stuck, so Shield stopped it. Try again.", action: .retry)
        }
        // The runner names its sandbox wrapper, not yt-dlp, when time runs out.
        if has("exceeded its time limit", "time limit") {
            return .init(text: "This download took too long and was stopped. Try again.", action: .retry)
        }
        if has("blocks youtube", "committed policy", "current protection") {
            return .init(text: "Paused while YouTube is blocked.", action: .none)
        }
        if has("timed out", "timeout", "network", "connection", "offline", "unable to download webpage",
               "temporary failure", "could not resolve", "resolutionfailed") {
            return .init(text: "No connection. Check your internet and try again.", action: .retry)
        }
        if has("interrupted") {
            return .init(text: "Stopped before it finished.", action: .retry)
        }
        if has("saved media is unavailable") {
            return .init(text: "The saved file is missing. Download or import it again.", action: .downloadAgain)
        }
        if has("import") {
            return .init(text: "Import failed. Choose the MP4 again.", action: .importAgain)
        }
        if has("validation", "playable", "invalid media", "failed checks", "mp4") {
            return .init(text: "The saved file didn't pass checks.", action: .downloadAgain)
        }
        if has("retry limit") {
            return .init(text: "Couldn't download after several tries.", action: .retry)
        }
        return .init(text: "Couldn't download this video.", action: .retry)
    }
}
