package com.cloudogu.gitops.utils

import org.junit.jupiter.api.Test

import static groovy.test.GroovyAssert.shouldFail
import static org.assertj.core.api.Assertions.assertThat

class DockerImageParserTest {
    @Test
    void 'parses simple image string'() {
        def result = DockerImageParser.parse("grafana/grafana:latest")

        assertThat(result.repository).isEqualTo("grafana/grafana")
        assertThat(result.tag).isEqualTo("latest")
    }

    @Test
    void 'parses image string with port'() {
        def result = DockerImageParser.parse("localhost:5000/grafana/grafana:latest")

        assertThat(result.repository).isEqualTo("localhost:5000/grafana/grafana")
        assertThat(result.tag).isEqualTo("latest")
    }

    @Test
    void 'splits into registry and repository'() {
        def result = DockerImageParser.parse("localhost:5000/the-registry/grafana/grafana:latest")

        def (registry, repository) = result.splitRegistryAndRepository()
        assertThat(registry).isEqualTo("localhost:5000/the-registry")
        assertThat(repository).isEqualTo("grafana/grafana")
        assertThat(result.tag).isEqualTo("latest")
    }

    @Test
    void 'throws when there is no colon'() {
        shouldFail(RuntimeException) {
            DockerImageParser.parse("grafana/grafana")
        }
    }
}
