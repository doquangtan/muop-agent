// Danh sách ảo hóa kiểu ListView.builder của Flutter: chỉ mục nằm trong (hoặc gần) vùng nhìn
// mới được đưa vào giao diện. Mỗi mục có chiều cao (cố định hoặc ước lượng); tổng chiều cao
// được cộng dồn để tính được vị trí từng mục và khoảng cần render cho một vị trí cuộn.

#[derive(Clone)]
pub struct VirtualList {
    heights: Vec<f32>,
    /// prefix[i] = tổng chiều cao của mục 0..i; độ dài = số mục + 1
    prefix: Vec<f32>,
}

impl Default for VirtualList {
    fn default() -> Self {
        Self::new(Vec::new())
    }
}

impl VirtualList {
    pub fn new(heights: Vec<f32>) -> Self {
        let mut list = VirtualList {
            heights,
            prefix: Vec::new(),
        };
        list.rebuild();
        list
    }

    fn rebuild(&mut self) {
        self.prefix.clear();
        self.prefix.reserve(self.heights.len() + 1);
        let mut acc = 0.0_f32;
        self.prefix.push(acc);
        for h in &self.heights {
            acc += h;
            self.prefix.push(acc);
        }
    }

    pub fn len(&self) -> usize {
        self.heights.len()
    }

    pub fn height(&self, i: usize) -> f32 {
        self.heights[i]
    }

    /// Vị trí đỉnh của mục `i` (i == len() trả về tổng chiều cao)
    pub fn top(&self, i: usize) -> f32 {
        self.prefix.get(i).copied().unwrap_or_else(|| self.total())
    }

    pub fn total(&self) -> f32 {
        *self.prefix.last().unwrap_or(&0.0)
    }

    /// Khoảng [start, end) cần render cho vùng nhìn `[offset, offset + view]`, nới thêm `buffer` mỗi phía
    pub fn range(&self, offset: f32, view: f32, buffer: f32) -> (usize, usize) {
        let n = self.len();
        if n == 0 {
            return (0, 0);
        }
        let y0 = (offset - buffer).max(0.0);
        let y1 = offset + view + buffer;
        // Mục chứa y0: chỉ số lớn nhất có prefix[i] <= y0
        let start = self
            .prefix
            .partition_point(|&p| p <= y0)
            .saturating_sub(1)
            .min(n - 1);
        // Mục đầu tiên bắt đầu từ y1 trở đi là điểm kết thúc (exclusive)
        let end = self
            .prefix
            .partition_point(|&p| p < y1)
            .min(n)
            .max(start + 1);
        (start, end)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn range_picks_only_visible_items() {
        // 100 mục, mỗi mục 50px → tổng 5000px
        let list = VirtualList::new(vec![50.0; 100]);
        assert_eq!(list.total(), 5000.0);
        // Vùng nhìn 0..400, không buffer: mục 0..8
        assert_eq!(list.range(0.0, 400.0, 0.0), (0, 8));
        // Cuộn tới 2000px: mục từ 40
        assert_eq!(list.range(2000.0, 400.0, 0.0), (40, 48));
        // Có buffer 100px mỗi phía
        assert_eq!(list.range(2000.0, 400.0, 100.0), (38, 50));
        // Cuối danh sách
        assert_eq!(list.range(4900.0, 400.0, 0.0), (98, 100));
    }

    #[test]
    fn empty_list_is_safe() {
        let list = VirtualList::default();
        assert_eq!(list.range(0.0, 500.0, 100.0), (0, 0));
        assert_eq!(list.total(), 0.0);
        assert_eq!(list.top(0), 0.0);
    }
}
