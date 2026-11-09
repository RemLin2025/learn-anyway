import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct DocumentTests {
    let db: AppDatabase
    let courses: CourseService
    let docs: DocumentService
    let dir: URL
    let courseId: UUID

    init() throws {
        db = try AppDatabase.inMemory()
        courses = CourseService(db: db)
        dir = try tempDir()
        docs = DocumentService(db: db, storage: ManagedStorage(root: dir.appendingPathComponent("storage")))
        courseId = try courses.createCourse(name: "COMP 211").id
    }

    @Test func pdfImportKeepsPagesHashAndOriginal() throws {
        let src = dir.appendingPathComponent("lecture.pdf")
        makePDF(pages: ["Iterators produce elements lazily one at a time", "Generics allow type parameters in classes"], at: src)
        let r = try docs.importFile(at: src, courseId: courseId)
        #expect(!r.wasDuplicate)
        #expect(r.document.kind == .pdf)
        #expect(r.document.pageCount == 2)
        #expect(r.document.extractionStatus == .ok)
        #expect(r.document.sha256.count == 64)
        let chunks = try docs.chunks(documentId: r.document.id)
        #expect(chunks.map(\.pageNumber) == [1, 2])
        #expect(chunks[0].text.contains("Iterators"))
        // Managed copy exists and differs from the source location.
        let stored = ManagedStorage(root: dir.appendingPathComponent("storage")).url(forStoredPath: r.document.storedPath)
        #expect(FileManager.default.fileExists(atPath: stored.path))
        #expect(stored != src)
    }

    @Test func blankPagesAreFlaggedNotSilentlyOcrd() throws {
        let src = dir.appendingPathComponent("scan.pdf")
        makePDF(pages: ["Real content on the first page of this PDF", ""], at: src)
        let d = try docs.importFile(at: src, courseId: courseId).document
        #expect(d.extractionStatus == .partial)
        #expect(d.lowContentPageCount == 1)
        #expect(d.extractionMethod == "pdfkit-text")
    }

    @Test func allBlankPDFIsFailedButPreserved() throws {
        let src = dir.appendingPathComponent("blank.pdf")
        makePDF(pages: ["", ""], at: src)
        let d = try docs.importFile(at: src, courseId: courseId).document
        #expect(d.extractionStatus == .failed)
        #expect(try docs.documents(courseId: courseId).count == 1)
    }

    @Test func duplicateImportIsIdempotent() throws {
        let src = dir.appendingPathComponent("a.txt")
        try "Recursion needs a base case.\n\nAnd a recursive step.".write(to: src, atomically: true, encoding: .utf8)
        let first = try docs.importFile(at: src, courseId: courseId)
        let second = try docs.importFile(at: src, courseId: courseId)
        #expect(second.wasDuplicate)
        #expect(second.document.id == first.document.id)
        #expect(try docs.documents(courseId: courseId).count == 1)
    }

    @Test func pastedTextAndLongTextChunking() throws {
        let para = String(repeating: "word ", count: 300) // ~1500 chars
        let r = try docs.importPasted(text: [para, para, para].joined(separator: "\n\n"), title: "", courseId: courseId)
        #expect(r.document.kind == .pasted)
        #expect(r.document.title == "Pasted notes")
        #expect(try docs.chunks(documentId: r.document.id).count == 3)
        #expect(throws: DocumentError.emptyText) { try docs.importPasted(text: "  \n", title: "x", courseId: courseId) }
    }

    @Test func rejectsUnsupportedAndFakePDFWithoutLeavingFiles() throws {
        let ppt = dir.appendingPathComponent("slides.pptx")
        try Data([1, 2, 3]).write(to: ppt)
        #expect(throws: DocumentError.unsupportedType("pptx")) { try docs.importFile(at: ppt, courseId: courseId) }
        let fake = dir.appendingPathComponent("fake.pdf")
        try "not a pdf".write(to: fake, atomically: true, encoding: .utf8)
        #expect(throws: DocumentError.notAPDF) { try docs.importFile(at: fake, courseId: courseId) }
        #expect(try docs.documents(courseId: courseId).isEmpty)
        let documentsDir = dir.appendingPathComponent("storage/Documents")
        #expect(!FileManager.default.fileExists(atPath: documentsDir.path))
    }

    @Test func assessmentCoverageAndCascade() throws {
        let m = try courses.addAssessment(courseId: courseId, name: "Midterm 2")
        let d = try docs.importPasted(text: "hello world notes here for the exam", title: "n", courseId: courseId).document
        try docs.setAssessmentCoverage(documentId: d.id, assessmentIds: [m.id])
        #expect(try docs.assessmentIds(documentId: d.id) == [m.id])
        try courses.deleteAssessment(m.id)
        #expect(try docs.assessmentIds(documentId: d.id).isEmpty) // document survives
        #expect(try docs.documents(courseId: courseId).count == 1)
    }
}


@Suite struct LegacyMigrationTests {
    @Test func copiesOldFolderRenamesDatabaseAndLeavesOldUntouched() throws {
        let base = try tempDir(), fm = FileManager.default
        let old = base.appendingPathComponent("CramLab"), new = base.appendingPathComponent("Braincell")
        try fm.createDirectory(at: old.appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: old.appendingPathComponent("cramlab.sqlite"))
        try Data("wal".utf8).write(to: old.appendingPathComponent("cramlab.sqlite-wal"))
        try Data("doc".utf8).write(to: old.appendingPathComponent("files/a.txt"))
        #expect(try ManagedStorage.migrateLegacy(from: old, to: new))
        #expect(try String(contentsOf: new.appendingPathComponent("braincell.sqlite")) == "db")
        #expect(try String(contentsOf: new.appendingPathComponent("braincell.sqlite-wal")) == "wal")
        #expect(try String(contentsOf: new.appendingPathComponent("files/a.txt")) == "doc")
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("cramlab.sqlite").path))
        #expect(fm.fileExists(atPath: old.appendingPathComponent("cramlab.sqlite").path))
        #expect(!fm.fileExists(atPath: new.path + ".migrating"))
    }

    @Test func doesNothingWhenNewExistsOrOldMissing() throws {
        let base = try tempDir(), fm = FileManager.default
        let old = base.appendingPathComponent("CramLab"), new = base.appendingPathComponent("Braincell")
        #expect(try !ManagedStorage.migrateLegacy(from: old, to: new))
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: old.appendingPathComponent("cramlab.sqlite"))
        #expect(try !ManagedStorage.migrateLegacy(from: old, to: new))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("braincell.sqlite").path))
    }
}
