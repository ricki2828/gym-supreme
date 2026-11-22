package app.gymsupreme.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

class ContractFixturesTest {
    @Test
    fun contractFixturesDirectoryHasFiles() {
        val dir = File("src/test/fixtures/contract")
        val files = dir.listFiles { f -> f.isFile && f.name.endsWith(".json") }.orEmpty()
        assertTrue(files.isNotEmpty(), "no contract fixtures in ${dir.absolutePath}")
    }
}
