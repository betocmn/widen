import Testing

@testable import WidenKit

@Suite("WidenKit smoke")
struct WidenKitSmokeTests {
    @Test func appStateInitialStatus() async throws {
        let state = await AppState()
        await #expect(state.connectionStatus == .notConnected)
    }
}

@Suite("SchemaIntrospectionService")
struct SchemaIntrospectionServiceTests {
    @Test func foreignKeySQLUsesReferencedConstraintJoin() {
        let sql = SchemaIntrospectionService.foreignKeysSQL
        #expect(sql.contains("information_schema.referential_constraints"))
        #expect(sql.contains("rc.unique_constraint_schema"))
        #expect(sql.contains("ccu.ordinal_position = kcu.position_in_unique_constraint"))
        #expect(!sql.contains("ccu.table_schema = tc.table_schema"))
    }
}
