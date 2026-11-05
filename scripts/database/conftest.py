def pytest_addoption(parser):
    parser.addoption(
        "--db",
        default="./output/ao3_tag_seeds.db",
        help="Path to ao3_tag_seeds.db (default: ./output/ao3_tag_seeds.db)",
    )
