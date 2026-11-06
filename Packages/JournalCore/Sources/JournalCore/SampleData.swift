// Made-up notebooks for trying the app and for the public showcase. Contains no real content.

import Foundation

extension AppDatabase {
    public func addSampleData() throws {
        let personal = try createNotebook(name: "Personal")
        let personalRef = TreeItemRef(kind: .notebook, id: personal.id)
        let journal = try createGroup(name: "Journal 2026", in: personalRef)
        let journalRef = TreeItemRef(kind: .group, id: journal.id)
        let november = try createSection(name: "November", in: journalRef)
        for title in ["A new start", "Morning walk", "Plans for winter"] {
            try createPage(title: title, sectionId: november.id)
        }
        let october = try createSection(name: "October", in: journalRef)
        try createPage(title: "First cold day", sectionId: october.id)
        let ideas = try createSection(name: "Ideas", in: personalRef)
        try createPage(title: "Places to visit", sectionId: ideas.id)

        let food = try createNotebook(name: "Food")
        let recipes = try createSection(name: "Recipes", in: TreeItemRef(kind: .notebook, id: food.id))
        for title in ["Tomato soup", "Weeknight pasta"] {
            try createPage(title: title, sectionId: recipes.id)
        }

        let learning = try createNotebook(name: "Learning")
        let learningRef = TreeItemRef(kind: .notebook, id: learning.id)
        let books = try createSection(name: "Book notes", in: learningRef)
        try createPage(title: "A novel about the sea", sectionId: books.id)
        let coding = try createSection(name: "Coding notes", in: learningRef)
        try createPage(title: "Swift basics", sectionId: coding.id)

        let colors: [(TreeItemRef, ItemColor)] = [
            (personalRef, .blue),
            (TreeItemRef(kind: .section, id: november.id), .orange),
            (TreeItemRef(kind: .section, id: october.id), .brown),
            (TreeItemRef(kind: .section, id: ideas.id), .yellow),
            (TreeItemRef(kind: .notebook, id: food.id), .red),
            (TreeItemRef(kind: .section, id: recipes.id), .green),
            (learningRef, .purple),
            (TreeItemRef(kind: .section, id: books.id), .teal),
            (TreeItemRef(kind: .section, id: coding.id), .pink),
        ]
        for (ref, color) in colors {
            try setColor(color, of: ref)
        }

        let formatting = try createPage(title: "Everything the editor can do", sectionId: coding.id)
        try savePageDocument(Self.formattingSample, id: formatting.id)

        let soup = try pages(sectionId: recipes.id).first { $0.title == "Tomato soup" }
        if let soup {
            try savePageDocument(PageDocument(blocks: [
                Block(runs: [TextRun("Roast the tomatoes first. A spoon of butter at the end makes it silky.")]),
            ]), id: soup.id)
        }

        // Invented sayings from invented people.
        try createQuote(text: "Plant the tree even if you will never sit in its shade.", author: "Mira Holloway", source: "Letters from the Orchard", tags: ["patience", "hope"], sectionId: books.id)
        try createQuote(text: "A quiet morning is a conversation you have with yourself.", author: "Mira Holloway", source: "Letters from the Orchard", tags: ["mornings"])
        try createQuote(text: "Courage is mostly remembering what you already decided.", author: "Tomas Reyna", source: "The Long Road Home", tags: ["courage"])
        try createQuote(text: "The sea does not hurry, and yet it reaches every shore.", author: "Tomas Reyna", source: "The Long Road Home", tags: ["patience", "nature"])
        try createQuote(text: "Good soup, like good advice, is better after a rest.", author: "Odile Fournier", source: "A Kitchen Year", tags: ["food", "humor"])
        try createQuote(text: "Write it down. Memory is a generous liar.", author: "Odile Fournier", tags: ["writing"])
        try createQuote(text: "Every expert was once embarrassed in public.", author: "Sam Adeyemi", tags: ["learning", "humor"])
    }

    private static func run(_ text: String, _ change: (inout TextStyle) -> Void) -> TextRun {
        var style = TextStyle()
        change(&style)
        return TextRun(text, style: style)
    }

    private static var formattingSample: PageDocument {
        PageDocument(blocks: [
            Block(kind: .heading1, runs: [TextRun("A big heading")]),
            Block(runs: [
                TextRun("Plain, "),
                run("bold") { $0.bold = true },
                TextRun(", "),
                run("italic") { $0.slant = .italic },
                TextRun(", "),
                run("backwards italic") { $0.slant = .backwards },
                TextRun(", "),
                run("struck through") { $0.strikethrough = true },
                TextRun(", "),
                run("underlined") { $0.underline = true },
                TextRun(" and "),
                run("a link") { $0.link = "https://example.com" },
                TextRun("."),
            ]),
            Block(runs: [
                run("Georgia ") { $0.font = "Georgia" },
                run("Snell Roundhand ") { $0.font = "Snell Roundhand"; $0.size = 22 },
                run("Menlo ") { $0.font = "Menlo" },
                run("large") { $0.size = 28 },
            ]),
            Block(kind: .heading2, runs: [TextRun("Lists")]),
            Block(kind: .bullet, runs: [TextRun("A bullet")]),
            Block(kind: .bullet, runs: [TextRun("A nested bullet")], level: 1),
            Block(kind: .bullet, runs: [TextRun("Nested again, with enough text to wrap onto a second line")], level: 2),
            Block(kind: .dash, runs: [TextRun("A dash")]),
            Block(kind: .dash, runs: [TextRun("A nested dash")], level: 1),
            Block(kind: .numbered, runs: [TextRun("First")]),
            Block(kind: .numbered, runs: [TextRun("Second")]),
            Block(kind: .numbered, runs: [TextRun("let code = \"inside a list\"\u{2028}print(code)")], textKind: .code),
            Block(kind: .checklist, runs: [TextRun("Something done")], isChecked: true),
            Block(kind: .checklist, runs: [TextRun("Something to do")]),
            Block(kind: .heading3, runs: [TextRun("Other blocks")]),
            Block(kind: .quote, runs: [TextRun("A quote from a book, kept here to read again.")]),
            Block(kind: .code, runs: [TextRun("let answer = 42")]),
            Block(kind: .code, runs: [TextRun("print(answer)")]),
            Block(kind: .divider),
            Block(kind: .table, table: TableData(rows: [
                ["Company", "Role", "Status"],
                ["Example Inc", "Developer", "Applied"],
            ])),
            Block(runs: [TextRun("Text after the table.")]),
        ])
    }
}
