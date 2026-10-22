from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROTOTYPE = ROOT / "prototype"


class WebsiteLegalPagesTests(unittest.TestCase):
    def test_privacy_page_explains_data_and_user_choices(self):
        page = PROTOTYPE / "privacy" / "index.html"
        self.assertTrue(page.is_file(), "privacy page must exist at /privacy")
        html = page.read_text(encoding="utf-8")
        for required in (
            "隐私政策", "我们处理哪些数据", "本机", "外部 AI",
            "HealthKit", "撤销", "删除", "排除在 iCloud 设备备份之外", "hello@wiselife.cloud",
            "WiseLife App 不提供云端服务",
            "你在 App 中创建的所有记录、转写、照片、总结和洞察默认保存在 iPhone 本机",
            "WiseLife 不运营接收、托管或同步个人记录的云端服务",
            "只有当你主动连接 ChatGPT", "音频和照片不会发送给外部 AI",
        ):
            with self.subTest(required=required):
                self.assertIn(required, html)

    def test_terms_page_describes_limits_and_purchase(self):
        page = PROTOTYPE / "terms" / "index.html"
        self.assertTrue(page.is_file(), "terms page must exist at /terms")
        html = page.read_text(encoding="utf-8")
        for required in (
            "服务条款", "AI 结果", "医疗", "录音", "App Store", "hello@wiselife.cloud",
            "WiseLife App 不提供云端服务", "不接收或托管这些内容",
        ):
            with self.subTest(required=required):
                self.assertIn(required, html)

    def test_homepage_links_to_policy_pages(self):
        html = (PROTOTYPE / "iphone-day.html").read_text(encoding="utf-8")
        self.assertIn('href="privacy/"', html)
        self.assertIn('href="terms/"', html)
        self.assertIn("WiseLife App 不提供云端服务", html)
        self.assertIn("你在 App 中创建的所有记录、转写、照片、总结和洞察默认保存在 iPhone 本机", html)
        self.assertIn("Apple Watch 录音会传回配对 iPhone 后保存", html)
        self.assertNotIn("是否使用云端、交给哪一个服务", html)
        self.assertNotIn("不依赖自建服务器", html)

    def test_cloud_service_promise_is_localized(self):
        story_copy = (PROTOTYPE / "wiselife-story-locales.js").read_text(encoding="utf-8")
        site_copy = (PROTOTYPE / "wiselife-site-locales.js").read_text(encoding="utf-8")
        for required in (
            "WiseLife has no cloud service; your daily records stay on your phone.",
            "WiseLife はクラウドサービスを提供しません。日々の記録はスマートフォンに保存されます。",
        ):
            with self.subTest(required=required):
                self.assertIn(required, story_copy)
        for required in (
            "All records, transcripts, photos, summaries and insights stay on your iPhone by default.",
            "すべての記録、文字起こし、写真、要約、インサイトは通常 iPhone 本体に保存されます。",
        ):
            with self.subTest(required=required):
                self.assertIn(required, site_copy)


if __name__ == "__main__":
    unittest.main()
